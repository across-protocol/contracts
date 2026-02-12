// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Script } from "forge-std/Script.sol";
import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";
import { Constants } from "./utils/Constants.sol";
import { CounterfactualDepositExecutor } from "../contracts/periphery/counterfactual/CounterfactualDepositExecutor.sol";
import { CounterfactualDepositFactory } from "../contracts/periphery/counterfactual/CounterfactualDepositFactory.sol";

// How to run:
// 1. `source .env` where `.env` has MNEMONIC="x x x ... x", ADMIN_ADDRESS="0x...",
//    SRC_PERIPHERY_ADDRESS="0x...", SOURCE_DOMAIN="0", and ETHERSCAN_API_KEY="x"
// 2. forge script script/001DeployCounterfactualDepositSystem.s.sol:DeployCounterfactualDepositSystem --rpc-url $NODE_URL_1 -vvvv
// 3. Verify simulation works
// 4. Deploy: forge script script/001DeployCounterfactualDepositSystem.s.sol:DeployCounterfactualDepositSystem --rpc-url $NODE_URL_1 --broadcast --verify -vvvv

contract DeployCounterfactualDepositSystem is Script, Test, Constants {
    function run() external {
        string memory deployerMnemonic = vm.envString("MNEMONIC");
        uint256 deployerPrivateKey = vm.deriveKey(deployerMnemonic, 0);

        // Get deployment parameters from environment
        address admin = vm.envAddress("ADMIN_ADDRESS");
        address srcPeriphery = vm.envAddress("SRC_PERIPHERY_ADDRESS");
        uint32 sourceDomain = uint32(vm.envUint("SOURCE_DOMAIN"));
        require(admin != address(0), "ADMIN_ADDRESS not set");
        require(srcPeriphery != address(0), "SRC_PERIPHERY_ADDRESS not set");

        console.log("=== Deploying Counterfactual Deposit System ===");
        console.log("Chain ID:", block.chainid);
        console.log("SrcPeriphery:", srcPeriphery);
        console.log("Source Domain:", sourceDomain);
        console.log("Admin:", admin);

        vm.startBroadcast(deployerPrivateKey);

        // Step 1: Deploy factory
        CounterfactualDepositFactory factory = new CounterfactualDepositFactory(admin);
        console.log("Factory deployed to:", address(factory));

        // Step 2: Deploy executor with factory, srcPeriphery, and sourceDomain as immutables
        CounterfactualDepositExecutor executor = new CounterfactualDepositExecutor(
            address(factory),
            srcPeriphery,
            sourceDomain
        );
        console.log("Executor deployed to:", address(executor));

        vm.stopBroadcast();

        console.log("=== Deployment Complete ===");
        console.log("Save these addresses for backend integration:");
        console.log("  Factory:", address(factory));
        console.log("  Executor:", address(executor));
    }
}
