// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Script } from "forge-std/Script.sol";
import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";
import { Arbitrum_RescueAdapter } from "../../contracts/chain-adapters/Arbitrum_RescueAdapter.sol";
import { Constants } from "../utils/Constants.sol";

import { ArbitrumInboxLike as ArbitrumL1InboxLike } from "../../contracts/interfaces/ArbitrumBridge.sol";

// How to run:
// 1. `source .env` where `.env` has MNEMONIC="x x x ... x" and ETHERSCAN_API_KEY="x" entries
// 2. forge script script/chain-adapters/DeployArbitrumRescueAdapter.s.sol:DeployArbitrumRescueAdapter --rpc-url $NODE_URL_1 -vvvv
// 3. Verify the above works in simulation mode.
// 4. Deploy on mainnet by adding --broadcast --verify flags.
// 5. forge script script/chain-adapters/DeployArbitrumRescueAdapter.s.sol:DeployArbitrumRescueAdapter --rpc-url $NODE_URL_1 --broadcast --verify -vvvv

contract DeployArbitrumRescueAdapter is Script, Test, Constants {
    function run() external {
        string memory deployerMnemonic = vm.envString("MNEMONIC");
        uint256 deployerPrivateKey = vm.deriveKey(deployerMnemonic, 0);

        // Get the current chain ID
        uint256 chainId = block.chainid;

        // Verify this is being deployed on Ethereum mainnet or Sepolia
        require(
            chainId == getChainId("MAINNET") || chainId == getChainId("SEPOLIA"),
            "Arbitrum_RescueAdapter should only be deployed on Ethereum mainnet or Sepolia"
        );

        // This L2 address receives the rescued ETH and all fee refunds. Currently set to the Risk Labs relayer
        // address, matching where the production Arbitrum_Adapter sends its L2 gas refunds. The deployer should
        // change this if necessary.
        address l2Recipient = 0x07aE8551Be970cB1cCa11Dd7a11F47Ae82e70E67;

        // Get L1 addresses for this chain
        Constants.L1Addresses memory l1Addresses = getL1Addresses(chainId);

        vm.startBroadcast(deployerPrivateKey);

        // Deploy Arbitrum_RescueAdapter with constructor parameters
        Arbitrum_RescueAdapter rescueAdapter = new Arbitrum_RescueAdapter(
            ArbitrumL1InboxLike(l1Addresses.l1ArbitrumInbox),
            l2Recipient
        );

        // Log the deployed addresses
        console.log("Chain ID:", chainId);
        console.log("Arbitrum_RescueAdapter deployed to:", address(rescueAdapter));
        console.log("L1 Arbitrum Inbox:", l1Addresses.l1ArbitrumInbox);
        console.log("L2 Recipient:", l2Recipient);

        vm.stopBroadcast();
    }
}
