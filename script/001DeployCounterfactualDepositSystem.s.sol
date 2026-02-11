// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Script } from "forge-std/Script.sol";
import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";
import { Constants } from "./utils/Constants.sol";
import { CounterfactualDepositExecutor } from "../contracts/periphery/counterfactual/CounterfactualDepositExecutor.sol";
import { CounterfactualDepositFactory } from "../contracts/periphery/counterfactual/CounterfactualDepositFactory.sol";

// How to run:
// 1. `source .env` where `.env` has MNEMONIC="x x x ... x", ADMIN_ADDRESS="0x...", QUOTE_SIGNER_ADDRESS="0x...", and ETHERSCAN_API_KEY="x"
// 2. forge script script/001DeployCounterfactualDepositSystem.s.sol:DeployCounterfactualDepositSystem --rpc-url $NODE_URL_1 -vvvv
// 3. Verify simulation works
// 4. Deploy: forge script script/001DeployCounterfactualDepositSystem.s.sol:DeployCounterfactualDepositSystem --rpc-url $NODE_URL_1 --broadcast --verify -vvvv

contract DeployCounterfactualDepositSystem is Script, Test, Constants {
    function run() external {
        string memory deployerMnemonic = vm.envString("MNEMONIC");
        uint256 deployerPrivateKey = vm.deriveKey(deployerMnemonic, 0);

        uint256 chainId = block.chainid;

        // Get SpokePool address for this chain
        address spokePool = getSpokePoolAddress(chainId);
        require(spokePool != address(0), "SpokePool not found for this chain");

        // Get admin and quote signer addresses from environment
        address admin = vm.envAddress("ADMIN_ADDRESS");
        address quoteSigner = vm.envAddress("QUOTE_SIGNER_ADDRESS");
        require(admin != address(0), "ADMIN_ADDRESS not set");
        require(quoteSigner != address(0), "QUOTE_SIGNER_ADDRESS not set");

        console.log("=== Deploying Counterfactual Deposit System ===");
        console.log("Chain ID:", chainId);
        console.log("SpokePool:", spokePool);
        console.log("Admin:", admin);
        console.log("Quote Signer:", quoteSigner);

        vm.startBroadcast(deployerPrivateKey);

        // Step 1: Deploy factory
        CounterfactualDepositFactory factory = new CounterfactualDepositFactory(spokePool, admin, quoteSigner);
        console.log("Factory deployed to:", address(factory));

        // Step 2: Deploy executor with factory and spokePool as immutables
        CounterfactualDepositExecutor executor = new CounterfactualDepositExecutor(address(factory), spokePool);
        console.log("Executor deployed to:", address(executor));

        vm.stopBroadcast();

        console.log("=== Deployment Complete ===");
        console.log("Save these addresses for backend integration:");
        console.log("  Factory:", address(factory));
        console.log("  Executor:", address(executor));
    }

    // Helper function to get SpokePool address for a given chain
    // This should be updated with actual deployed SpokePool addresses
    function getSpokePoolAddress(uint256 chainId) internal view returns (address) {
        // Mainnet
        if (chainId == getChainId("MAINNET")) return 0x5c7BCd6E7De5423a257D81B442095A1a6ced35C5;
        // Optimism
        if (chainId == getChainId("OPTIMISM")) return 0x6f26Bf09B1C792e3228e5467807a900A503c0281;
        // Polygon
        if (chainId == getChainId("POLYGON")) return 0x9295ee1d8C5b022Be115A2AD3c30C72E34e7F096;
        // Arbitrum
        if (chainId == getChainId("ARBITRUM")) return 0xe35e9842fceaCA96570B734083f4a58e8F7C5f2A;
        // Base
        if (chainId == getChainId("BASE")) return 0x09aea4b2242abC8bb4BB78D537A67a245A7bEC64;
        // ZkSync
        if (chainId == getChainId("ZK_SYNC")) return 0xE0B015E54d54fc84a6cB9B666099c46adE9335FF;
        // Linea
        if (chainId == getChainId("LINEA")) return 0x7E63A5f1a8F0B4d0934B2f2327DAED3F6bb2ee75;
        // Scroll
        if (chainId == getChainId("SCROLL")) return 0x3baD7AD0728f9917d1Bf08af5782dCbD516cDd96;
        // Sepolia (testnet)
        if (chainId == getChainId("SEPOLIA")) return 0x5ef6C01E11889d86803e0B23e3cB3F9E9d97B662;

        return address(0);
    }
}
