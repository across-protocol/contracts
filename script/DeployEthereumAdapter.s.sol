// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Script } from "forge-std/Script.sol";
import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";
import { Ethereum_Adapter } from "../contracts/chain-adapters/Ethereum_Adapter.sol";
import { Constants } from "./utils/Constants.sol";

// How to run:
// 1. `source .env` where `.env` has MNEMONIC="x x x ... x" and ETHERSCAN_API_KEY="x" entries
// 2. forge script script/006DeployEthereumAdapter.s.sol:DeployEthereumAdapter --rpc-url $NODE_URL_1 -vvvv
// 3. Verify the above works in simulation mode.
// 4. Deploy on mainnet by adding --broadcast --verify flags.
// 5. forge script script/006DeployEthereumAdapter.s.sol:DeployEthereumAdapter --rpc-url $NODE_URL_1 --broadcast --verify -vvvv

contract DeployEthereumAdapter is Script, Test, Constants {
    function run() external {
        string memory deployerMnemonic = vm.envString("MNEMONIC");
        uint256 deployerPrivateKey = vm.deriveKey(deployerMnemonic, 0);

        // Get the current chain ID
        uint256 chainId = block.chainid;

        // Verify this is being deployed on Ethereum mainnet or Sepolia
        require(
            chainId == getChainId("MAINNET") || chainId == getChainId("SEPOLIA"),
            "Ethereum_Adapter should only be deployed on Ethereum mainnet or Sepolia"
        );

        vm.startBroadcast(deployerPrivateKey);

        // Deploy Ethereum_Adapter (no constructor parameters needed)
        Ethereum_Adapter ethereumAdapter = new Ethereum_Adapter();

        // Log the deployed addresses
        console.log("Chain ID:", chainId);
        console.log("Ethereum_Adapter deployed to:", address(ethereumAdapter));

        vm.stopBroadcast();
    }
}
