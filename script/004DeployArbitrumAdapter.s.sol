// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Script } from "forge-std/Script.sol";
import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Arbitrum_Adapter } from "../contracts/chain-adapters/Arbitrum_Adapter.sol";
import { Constants } from "./utils/Constants.sol";

import { ITokenMessenger } from "../contracts/external/interfaces/CCTPInterfaces.sol";
import { ArbitrumInboxLike as ArbitrumL1InboxLike, ArbitrumL1ERC20GatewayLike } from "../contracts/interfaces/ArbitrumBridge.sol";

// How to run:
// 1. `source .env` where `.env` has MNEMONIC="x x x ... x" and ETHERSCAN_API_KEY="x" entries
// 2. forge script script/004DeployArbitrumAdapter.s.sol:DeployArbitrumAdapter --rpc-url $NODE_URL_1 -vvvv
// 3. Verify the above works in simulation mode.
// 4. Deploy on mainnet by adding --broadcast --verify flags.
// 5. forge script script/004DeployArbitrumAdapter.s.sol:DeployArbitrumAdapter --rpc-url $NODE_URL_1 --broadcast --verify -vvvv

contract DeployArbitrumAdapter is Script, Test, Constants {
    function run() external {
        string memory deployerMnemonic = vm.envString("MNEMONIC");
        uint256 deployerPrivateKey = vm.deriveKey(deployerMnemonic, 0);

        // Get the current chain ID
        uint256 chainId = block.chainid;

        // Verify this is being deployed on Ethereum mainnet or Sepolia
        require(
            chainId == getChainId("MAINNET") || chainId == getChainId("SEPOLIA"),
            "Arbitrum_Adapter should only be deployed on Ethereum mainnet or Sepolia"
        );

        // This address receives gas refunds on the L2 after messages are relayed. Currently
        // set to the Risk Labs relayer address. The deployer should change this if necessary.
        address l2RefundAddress = 0x07aE8551Be970cB1cCa11Dd7a11F47Ae82e70E67;

        // Determine the spoke chain ID (Arbitrum mainnet or testnet)
        uint256 spokeChainId;
        if (chainId == getChainId("MAINNET")) {
            spokeChainId = getChainId("ARBITRUM");
        } else {
            spokeChainId = getChainId("ARBITRUM_SEPOLIA");
        }

        // Get OFT destination endpoint ID and fee cap
        uint32 oftDstEid = uint32(getOftEid(spokeChainId));
        uint256 oftFeeCap = 1e18; // 1 eth transfer fee cap

        // Get L1 addresses for this chain
        Constants.L1Addresses memory l1Addresses = getL1Addresses(chainId);

        vm.startBroadcast(deployerPrivateKey);

        // Deploy Arbitrum_Adapter with constructor parameters
        Arbitrum_Adapter arbitrumAdapter = new Arbitrum_Adapter(
            ArbitrumL1InboxLike(l1Addresses.l1ArbitrumInbox),
            ArbitrumL1ERC20GatewayLike(l1Addresses.l1ERC20GatewayRouter),
            l2RefundAddress,
            IERC20(getUSDCAddress(chainId)),
            ITokenMessenger(l1Addresses.cctpTokenMessenger),
            l1Addresses.adapterStore, // This might need to be deployed first or set to address(0)
            oftDstEid,
            oftFeeCap
        );

        // Log the deployed addresses
        console.log("Chain ID:", chainId);
        console.log("Arbitrum_Adapter deployed to:", address(arbitrumAdapter));
        console.log("L1 Arbitrum Inbox:", l1Addresses.l1ArbitrumInbox);
        console.log("L1 ERC20 Gateway Router:", l1Addresses.l1ERC20GatewayRouter);
        console.log("L2 Refund Address:", l2RefundAddress);
        console.log("USDC Address:", getUSDCAddress(chainId));
        console.log("CCTP Token Messenger:", l1Addresses.cctpTokenMessenger);
        console.log("Adapter Store:", l1Addresses.adapterStore);
        console.log("OFT Destination EID:", oftDstEid);
        console.log("OFT Fee Cap:", oftFeeCap);

        vm.stopBroadcast();
    }
}
