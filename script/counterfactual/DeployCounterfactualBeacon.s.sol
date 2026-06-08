// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { console } from "forge-std/console.sol";
import { CounterfactualConfig } from "./CounterfactualConfig.sol";
import { CounterfactualBeacon } from "../../contracts/periphery/counterfactual/CounterfactualBeacon.sol";

// Deploys the counterfactual beacon stack so the beacon PROXY lands at the SAME address on every chain
// (every counterfactual proxy and the factory embed it as their beacon):
//   1. CounterfactualBeacon implementation via CREATE2 (no constructor args => same address everywhere).
//   2. ERC1967Proxy via CREATE2, initialized with the deployer (chain-invariant, from MNEMONIC) as owner and
//      a zero implementation/upgradeRoot. Identical init code => identical proxy address across chains.
//      (Do NOT put the per-chain multisig in the init calldata — that would make the proxy address differ.)
//   3. The dispatcher (CounterfactualDeposit) via CREATE2, bound to the chain-invariant proxy.
//   4. setImplementation(dispatcher) so every counterfactual proxy resolves the dispatcher.
//   5. Optionally transferOwnership(ownerAndDirectWithdrawer) (Ownable2Step; the new owner accepts out of band).
//
// How to run:
// 1. Edit script/counterfactual/config.toml with signer + ownerAndDirectWithdrawer per chain
// 2. `source .env` where `.env` has MNEMONIC="x x x ... x" and ETHERSCAN_API_KEY="x"
// 3. forge script script/counterfactual/DeployCounterfactualBeacon.s.sol:DeployCounterfactualBeacon \
//      --rpc-url $NODE_URL -vvvv
// 4. Deploy: append --broadcast --verify to the command above.
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
        uint256 deployerPrivateKey = vm.deriveKey(vm.envString("MNEMONIC"), 0);
        address deployer = vm.addr(deployerPrivateKey);

        address proxy = _predictBeaconProxy(deployer);
        address dispatcher = _predictCreate2(bytes32(0), _dispatcherInitCode(proxy));

        console.log("============================================");
        console.log("Counterfactual Beacon stack deployment");
        console.log("============================================");
        console.log("Chain ID:            ", block.chainid);
        console.log("Deployer:            ", deployer);
        console.log("Predicted proxy:     ", proxy);
        console.log("Predicted dispatcher:", dispatcher);

        vm.startBroadcast(deployerPrivateKey);

        // 1 + 2. Beacon implementation and proxy (both CREATE2 => chain-invariant addresses).
        _deployCreate2(bytes32(0), _beaconImplInitCode());
        address deployedProxy = _deployCreate2(bytes32(0), _beaconProxyInitCode(deployer));
        require(deployedProxy == proxy, "proxy address mismatch");

        // 3. Dispatcher bound to the proxy.
        address deployedDispatcher = _deployCreate2(bytes32(0), _dispatcherInitCode(deployedProxy));
        require(deployedDispatcher == dispatcher, "dispatcher address mismatch");

        // 4. Point the beacon at the dispatcher so every counterfactual proxy runs it.
        CounterfactualBeacon beacon = CounterfactualBeacon(deployedProxy);
        if (beacon.implementation() != deployedDispatcher) beacon.setImplementation(deployedDispatcher);

        // 5. Optionally hand the beacon over to the per-chain multisig (Ownable2Step accept out of band).
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
        console.log("Dispatcher:          ", deployedDispatcher);
        console.log("============================================");
        console.log("Beacon stack deployed.");
        console.log("============================================");
    }
}
