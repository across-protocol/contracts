// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { console } from "forge-std/console.sol";
import { CounterfactualConfig } from "./CounterfactualConfig.sol";
import { CounterfactualDepositSpokePool } from "../../contracts/periphery/counterfactual/CounterfactualDepositSpokePool.sol";

// Deploys the SpokePool leaf implementation. It is input-token-agnostic: the leaf names its input token by
// the beacon getter selector (`inputTokenGetter`), and the SpokePool, wrapped native token and fee signer
// are resolved from the CounterfactualBeacon at runtime. With no constructor args it gets the SAME CREATE2
// address on every chain.
//
// How to run (zero-arg):
// 1. `source .env` where `.env` has MNEMONIC="x x x ... x" and ETHERSCAN_API_KEY="x"
// 2. forge script script/counterfactual/DeployCounterfactualDepositSpokePool.s.sol:DeployCounterfactualDepositSpokePool \
//      --rpc-url $NODE_URL -vvvv
// 3. Deploy: append --broadcast --verify to the command above
contract DeployCounterfactualDepositSpokePool is CounterfactualConfig {
    /// @notice Zero-arg entry point.
    function run() external {
        uint256 deployerPrivateKey = vm.deriveKey(vm.envString("MNEMONIC"), 0);

        console.log("Deploying CounterfactualDepositSpokePool via CREATE2...");
        console.log("Chain ID:", block.chainid);

        vm.startBroadcast(deployerPrivateKey);
        address deployed = _deployCreate2(bytes32(0), type(CounterfactualDepositSpokePool).creationCode);
        vm.stopBroadcast();

        console.log("CounterfactualDepositSpokePool deployed to:", deployed);
    }
}
