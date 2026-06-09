// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { console } from "forge-std/console.sol";
import { CounterfactualConfig } from "./CounterfactualConfig.sol";
import {
    CounterfactualBeacon,
    CounterfactualChainConfig
} from "../../contracts/periphery/counterfactual/CounterfactualBeacon.sol";
import { CounterfactualBeaconBootstrap } from "../../contracts/periphery/counterfactual/CounterfactualBeaconBootstrap.sol";

// Deploys the full counterfactual beacon stack so the beacon **proxy** lands at the SAME address on every
// chain (every counterfactual proxy and the factory embed it):
//   1. CounterfactualBeaconBootstrap via CREATE2 (no constructor args => same address everywhere).
//   2. ERC1967Proxy via CREATE2 over the bootstrap, init calldata = bootstrap.initialize(deployer). The
//      deployer (chain-invariant, from MNEMONIC) is the bootstrap owner => identical init code => identical
//      proxy address. (Do NOT put the per-chain multisig in the init calldata — that breaks address parity.)
//   3. The chain-specific CounterfactualBeacon impl via `new CounterfactualBeacon(config)` (per-chain address;
//      fine — it lives behind the address-stable proxy).
//   4. As deployer/current owner, `upgradeToAndCall(beaconImpl, "")` to retarget the proxy to the real impl.
//   5. The dispatcher `new CounterfactualDeposit(ICounterfactualBeacon(proxy))` via CREATE2 (proxy is
//      chain-invariant => dispatcher is same address everywhere).
//   6. `setImplementation(dispatcher)` on the proxy so every counterfactual proxy resolves the dispatcher.
//   7. Optionally `transferOwnership(ownerAndDirectWithdrawer)` (Ownable2Step; new owner accepts out of band).
//
// How to run:
// 1. Edit script/counterfactual/config.toml with signer + ownerAndDirectWithdrawer per chain
// 2. `source .env` where `.env` has MNEMONIC="x x x ... x" and ETHERSCAN_API_KEY="x"
// 3. forge script script/counterfactual/DeployCounterfactualBeacon.s.sol:DeployCounterfactualBeacon \
//      --rpc-url $NODE_URL -vvvv
// 4. Deploy: append --broadcast --verify (add --sig "run(bool)" true to also hand the beacon to the multisig)
contract DeployCounterfactualBeacon is CounterfactualConfig {
    /// @notice Zero-arg entry point: deploys the beacon stack, keeping the deployer as owner.
    function run() external {
        _run(false);
    }

    /// @param transferOwnership If true, transfer beacon ownership to config.toml `ownerAndDirectWithdrawer`
    ///        (Ownable2Step — the new owner accepts out of band).
    function run(bool transferOwnership) external {
        _run(transferOwnership);
    }

    function _run(bool doTransferOwnership) internal {
        uint256 deployerPrivateKey = vm.deriveKey(vm.envString("MNEMONIC"), 0);
        address deployer = vm.addr(deployerPrivateKey);

        CounterfactualChainConfig memory chainConfig = _buildChainConfig();
        bytes32 salt = _deploySalt();
        bytes memory proxyInitCode = _beaconProxyInitCode(deployer);
        address proxy = _predictCreate2(salt, proxyInitCode);
        address dispatcher = _predictDispatcher(proxy);

        console.log("============================================");
        console.log("Counterfactual Beacon stack deployment");
        console.log("============================================");
        console.log("Chain ID:           ", block.chainid);
        console.log("Deployer:           ", deployer);
        console.log("Predicted proxy:    ", proxy);
        console.log("Predicted dispatcher:", dispatcher);

        vm.startBroadcast(deployerPrivateKey);

        // 1. Bootstrap (chain-identical init code).
        address bootstrap = _deployCreate2(salt, type(CounterfactualBeaconBootstrap).creationCode);
        console.log("Bootstrap:          ", bootstrap);

        // 2. Beacon proxy over the bootstrap (chain-identical init code => same address).
        address deployedProxy = _deployCreate2(salt, proxyInitCode);
        require(deployedProxy == proxy, "proxy address mismatch");
        console.log("Beacon proxy:       ", deployedProxy);

        // 3. Chain-specific beacon implementation (per-chain address, behind the proxy).
        address beaconImpl = address(new CounterfactualBeacon(chainConfig));
        console.log("Beacon impl:        ", beaconImpl);

        // 4. Upgrade the proxy from the bootstrap to the real beacon impl. The bootstrap already consumed the
        //    initializer slot, so pass empty calldata (no re-init); chain config comes from the impl's
        //    immutables, and implementation/upgradeRoot are set via owner setters.
        CounterfactualBeaconBootstrap(payable(deployedProxy)).upgradeToAndCall(beaconImpl, "");

        // 5. Dispatcher (CounterfactualDeposit), bound to the chain-invariant proxy => same address.
        address deployedDispatcher = _deployCreate2(salt, _dispatcherInitCode(deployedProxy));
        require(deployedDispatcher == dispatcher, "dispatcher address mismatch");
        console.log("Dispatcher:         ", deployedDispatcher);

        // 6. Point the beacon at the dispatcher so every counterfactual proxy runs it.
        CounterfactualBeacon beacon = CounterfactualBeacon(deployedProxy);
        if (beacon.implementation() != deployedDispatcher) beacon.setImplementation(deployedDispatcher);

        // 7. Optionally hand the beacon over to the per-chain multisig (Ownable2Step accept out of band).
        if (doTransferOwnership) {
            address newOwner = config.get("ownerAndDirectWithdrawer").toAddress();
            require(newOwner != address(0), "config: ownerAndDirectWithdrawer is zero or missing");
            if (beacon.owner() != newOwner) {
                console.log("Transferring beacon ownership to:", newOwner);
                beacon.transferOwnership(newOwner);
            }
        }

        vm.stopBroadcast();

        console.log("============================================");
        console.log("Beacon stack deployed.");
        console.log("============================================");
    }
}
