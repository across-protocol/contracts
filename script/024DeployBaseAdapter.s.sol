// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Script } from "forge-std/Script.sol";
import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";
import { Base_Adapter } from "../contracts/chain-adapters/Base_Adapter.sol";
import { Constants } from "./utils/Constants.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ITokenMessenger } from "../contracts/external/interfaces/CCTPInterfaces.sol";
import { IL1StandardBridge } from "@eth-optimism/contracts/L1/messaging/IL1StandardBridge.sol";
import { WETH9Interface } from "../contracts/external/interfaces/WETH9Interface.sol";

// How to run:
// 1. `source .env` where `.env` has MNEMONIC="x x x ... x" and ETHERSCAN_API_KEY="x" entries
// 2. forge script script/024DeployBaseAdapter.s.sol:DeployBaseAdapter --rpc-url $NODE_URL_1 -vvvv
// 3. Verify the above works in simulation mode.
// 4. Deploy on mainnet by adding --broadcast --verify flags.
// 5. forge script script/024DeployBaseAdapter.s.sol:DeployBaseAdapter --rpc-url $NODE_URL_1 --broadcast --verify -vvvv

contract DeployBaseAdapter is Script, Test, Constants {
    function run() external {
        string memory deployerMnemonic = vm.envString("MNEMONIC");
        uint256 deployerPrivateKey = vm.deriveKey(deployerMnemonic, 0);

        // Get the current chain ID
        uint256 chainId = block.chainid;

        // Verify this is being deployed on Ethereum mainnet or Sepolia
        require(
            chainId == getChainId("MAINNET") || chainId == getChainId("SEPOLIA"),
            "Base_Adapter should only be deployed on Ethereum mainnet or Sepolia"
        );

        address weth = getWrappedNativeToken(chainId);

        // Get OP Stack addresses for this chain and Base
        uint256 baseChainId = getChainId("BASE");
        Constants.OpStackAddresses memory opStack = getOpStackAddresses(chainId, baseChainId);

        vm.startBroadcast(deployerPrivateKey);

        // Deploy Base_Adapter with constructor parameters
        Base_Adapter baseAdapter = new Base_Adapter(
            WETH9Interface(weth), // L1 WETH
            opStack.L1CrossDomainMessenger, // L1 Cross Domain Messenger
            IL1StandardBridge(opStack.L1StandardBridge), // L1 Standard Bridge
            IERC20(getUSDCAddress(chainId)), // L1 USDC
            ITokenMessenger(getL1Addresses(chainId).cctpV2TokenMessenger) // CCTP V2 Token Messenger
        );

        // Log the deployed addresses
        console.log("Chain ID:", chainId);
        console.log("Base_Adapter deployed to:", address(baseAdapter));
        console.log("L1 WETH:", weth);
        console.log("L1 Cross Domain Messenger:", opStack.L1CrossDomainMessenger);
        console.log("L1 Standard Bridge:", opStack.L1StandardBridge);
        console.log("L1 USDC:", getUSDCAddress(chainId));
        console.log("CCTP Token Messenger:", getL1Addresses(chainId).cctpV2TokenMessenger);

        vm.stopBroadcast();
    }
}
