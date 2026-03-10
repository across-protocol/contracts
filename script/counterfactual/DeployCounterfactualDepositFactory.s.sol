// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Script } from "forge-std/Script.sol";
import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";

import { CounterfactualDepositFactory } from "../../contracts/periphery/counterfactual/CounterfactualDepositFactory.sol";

// How to run:
// 1. `source .env` where `.env` has MNEMONIC="x x x ... x" and ETHERSCAN_API_KEY="x"
// 2. forge script script/counterfactual/DeployCounterfactualDepositFactory.s.sol:DeployCounterfactualDepositFactory --rpc-url $NODE_URL -vvvv
// 3. Verify simulation works
// 4. Deploy: forge script script/counterfactual/DeployCounterfactualDepositFactory.s.sol:DeployCounterfactualDepositFactory --rpc-url $NODE_URL --broadcast --verify -vvvv
contract DeployCounterfactualDepositFactory is Script, Test {
    function run() external {
        string memory deployerMnemonic = vm.envString("MNEMONIC");
        uint256 deployerPrivateKey = vm.deriveKey(deployerMnemonic, uint32(vm.envUint("DEPLOYER_INDEX")));

        console.log("Deploying CounterfactualDepositFactory...");
        console.log("Chain ID:", block.chainid);

        vm.startBroadcast(deployerPrivateKey);

        CounterfactualDepositFactory factory = new CounterfactualDepositFactory();

        console.log("CounterfactualDepositFactory deployed to:", address(factory));

        vm.stopBroadcast();
    }
}
