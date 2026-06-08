// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { console } from "forge-std/console.sol";
import { CounterfactualConfig } from "./CounterfactualConfig.sol";
import { CounterfactualBeacon } from "../../contracts/periphery/counterfactual/CounterfactualBeacon.sol";

// Deploys the counterfactual beacon (impl + proxy) and WIRES it to the dispatcher. The beacon PROXY lands
// at the SAME address on every chain (every counterfactual proxy and the factory embed it as their beacon):
//   1. CounterfactualBeacon implementation via CREATE2 (no constructor args => same address everywhere).
//   2. ERC1967Proxy via CREATE2, initialized with the deployer (chain-invariant, from MNEMONIC) as owner and
//      a zero implementation/upgradeRoot. Identical init code => identical proxy address across chains.
//      (Do NOT put the per-chain multisig in the init calldata — that would make the proxy address differ.)
//   3. setImplementation(dispatcher) so every counterfactual proxy resolves the dispatcher.
//   4. Optionally transferOwnership(ownerAndDirectWithdrawer) (Ownable2Step; the new owner accepts out of band).
//
// The dispatcher itself is deployed by DeployCounterfactualDeposit (its own script + broadcast artifact);
// this script only WIRES it. So DeployCounterfactualDeposit must run first (DeployAllCounterfactual orders
// it that way). If the dispatcher isn't on-chain yet, wiring is skipped with a warning rather than reverting
// — expected during a no-broadcast dry run, where the prior script's simulated deploy doesn't persist.
//
// How to run:
// 1. Edit script/counterfactual/config.toml with signer + ownerAndDirectWithdrawer per chain
// 2. `source .env` where `.env` has MNEMONIC="x x x ... x" and ETHERSCAN_API_KEY="x"
// 3. Deploy the dispatcher first: forge script .../DeployCounterfactualDeposit.s.sol ... --broadcast
// 4. forge script script/counterfactual/DeployCounterfactualBeacon.s.sol:DeployCounterfactualBeacon \
//      --rpc-url $NODE_URL -vvvv  (append --broadcast --verify to deploy)
//    To also hand the beacon over to the multisig: --sig "run(bool)" true
contract DeployCounterfactualBeacon is CounterfactualConfig {
    /// @notice Zero-arg entry point: deploys the beacon stack and keeps the deployer as owner.
    function run() external {
        _run(false);
    }

    /// @param transferOwnership If true, transfer beacon ownership to config.toml `ownerAndDirectWithdrawer`
    ///        (Ownable2Step — the new owner accepts out of band).
    function run(bool transferOwnership) external {
        _run(transferOwnership);
    }

    function _run(bool doTransferOwnership) internal {
        _loadCounterfactualConfig();
        bytes32 salt = _loadSalt();
        uint256 deployerPrivateKey = vm.deriveKey(vm.envString("MNEMONIC"), 0);
        address deployer = vm.addr(deployerPrivateKey);

        address proxy = _predictBeaconProxy(deployer, salt);
        address dispatcher = _predictCreate2(salt, _dispatcherInitCode(proxy));

        console.log("============================================");
        console.log("Counterfactual Beacon stack deployment");
        console.log("============================================");
        console.log("Chain ID:            ", block.chainid);
        console.log("Deployer:            ", deployer);
        console.log("Predicted proxy:     ", proxy);
        console.log("Predicted dispatcher:", dispatcher);

        vm.startBroadcast(deployerPrivateKey);

        // 1 + 2. Beacon implementation and proxy (both CREATE2 => chain-invariant addresses).
        _deployCreate2(salt, _beaconImplInitCode());
        address deployedProxy = _deployCreate2(salt, _beaconProxyInitCode(deployer, salt));
        require(deployedProxy == proxy, "proxy address mismatch");

        // 3. Wire the beacon to the dispatcher (deployed separately by DeployCounterfactualDeposit). Skip if
        //    the dispatcher isn't on-chain yet (expected in a dry run) — `setImplementation` would otherwise
        //    revert in `_validateImplementation`. A real deploy runs the dispatcher script first, so this wires.
        CounterfactualBeacon beacon = CounterfactualBeacon(deployedProxy);
        if (dispatcher.code.length == 0) {
            console.log("WARNING: dispatcher not deployed yet; skipping setImplementation.");
            console.log("  Run DeployCounterfactualDeposit first (dry runs don't persist the prior step).");
        } else if (beacon.implementation() != dispatcher) {
            beacon.setImplementation(dispatcher);
        }

        // 4. Optionally hand the beacon over to the per-chain multisig (Ownable2Step accept out of band).
        if (doTransferOwnership) {
            address newOwner = config.get("ownerAndDirectWithdrawer").toAddress();
            require(newOwner != address(0), "config: ownerAndDirectWithdrawer is zero or missing");
            if (beacon.owner() != newOwner) {
                console.log("Transferring beacon ownership to:", newOwner);
                beacon.transferOwnership(newOwner);
            }
        }

        vm.stopBroadcast();

        console.log("Beacon proxy:        ", deployedProxy);
        console.log("Dispatcher (wired):  ", dispatcher);
        console.log("============================================");
        console.log("Beacon deployed and wired.");
        console.log("============================================");
    }
}
