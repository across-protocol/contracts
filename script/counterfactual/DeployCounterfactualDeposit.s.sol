// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { console } from "forge-std/console.sol";
import { CounterfactualConfig } from "./CounterfactualConfig.sol";

// Deploys the CounterfactualDeposit dispatcher, bound to the chain-invariant beacon proxy. The beacon stack
// (DeployCounterfactualBeacon) deploys this as part of its flow; this standalone script is for redeploying
// the dispatcher against an already-deployed beacon. The beacon proxy address is derived deterministically
// from the deployer (see CounterfactualConfig), so the beacon need not exist yet to compute it — but you
// must run DeployCounterfactualBeacon afterward (or before) to `setImplementation(dispatcher)`.
//
// How to run:
// 1. `source .env` where `.env` has MNEMONIC="x x x ... x" and ETHERSCAN_API_KEY="x"
// 2. forge script script/counterfactual/DeployCounterfactualDeposit.s.sol:DeployCounterfactualDeposit --rpc-url $NODE_URL -vvvv
// 3. Verify simulation works
// 4. Deploy: append --broadcast --verify to the command above
contract DeployCounterfactualDeposit is CounterfactualConfig {
    function run() external {
        uint256 deployerPrivateKey = vm.deriveKey(vm.envString("MNEMONIC"), 0);
        bytes32 salt = _loadSalt();
        address beaconProxy = _predictBeaconProxy(vm.addr(deployerPrivateKey), salt);

        bytes memory initCode = _dispatcherInitCode(beaconProxy);

        console.log("Deploying CounterfactualDeposit via CREATE2...");
        console.log("Chain ID:", block.chainid);
        console.log("Beacon proxy:", beaconProxy);

        vm.startBroadcast(deployerPrivateKey);
        address deployed = _deployCreate2(salt, initCode);
        vm.stopBroadcast();

        console.log("CounterfactualDeposit deployed to:", deployed);
    }
}
