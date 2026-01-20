// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Script } from "forge-std/Script.sol";
import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";
import { OP_Adapter } from "../contracts/chain-adapters/OP_Adapter.sol";
import { Constants } from "./utils/Constants.sol";
import { CircleDomainIds } from "../contracts/libraries/CircleCCTPAdapter.sol";
import { IERC20 } from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";
import { ITokenMessenger } from "../contracts/external/interfaces/CCTPInterfaces.sol";
import { IOpUSDCBridgeAdapter } from "../contracts/external/interfaces/IOpUSDCBridgeAdapter.sol";
import { IL1StandardBridge } from "@eth-optimism/contracts/L1/messaging/IL1StandardBridge.sol";
import { WETH9Interface } from "../contracts/external/interfaces/WETH9Interface.sol";

// How to run:
// 1. `source .env` where `.env` has MNEMONIC="x x x ... x" and ETHERSCAN_API_KEY="x" entries
// 2. forge script script/DeployOPAdapter.s.sol:DeployOPAdapter --rpc-url $NODE_URL_1 -vvvv
// 3. Verify the above works in simulation mode.
// 4. Deploy on mainnet by adding --broadcast --verify flags.
// 5. forge script script/DeployOPAdapter.s.sol:DeployOPAdapter --rpc-url $NODE_URL_1 --broadcast --verify -vvvv
contract DeployOPAdapter is Script, Test, Constants {
    function run() external {
        string memory deployerMnemonic = vm.envString("MNEMONIC");
        uint256 opChainId = vm.envUint("SPOKE_CHAIN_ID");
        uint256 deployerPrivateKey = vm.deriveKey(deployerMnemonic, 0);

        // Get the current chain ID
        uint256 chainId = block.chainid;
        address usdc = getUSDCAddress(chainId);
        bool hasCctpDomain = hasCctpDomain(destinationChainId);
        uint32 cctpDomain = hasCctpDomain ? getCircleDomainId(opChainId) : CCTP_NO_DOMAIN;
        address cctpTokenMessenger = hasCctpDomain ? getL1Addresses(chainId).cctpV2TokenMessenger : address(0);

        // Verify this is being deployed on Ethereum mainnet or Sepolia
        require(
            chainId == getChainId("MAINNET") || chainId == getChainId("SEPOLIA"),
            "OP_Adapter should only be deployed on Ethereum mainnet or Sepolia"
        );

        address weth = getWrappedNativeToken(chainId);

        // Get OP Stack addresses for hub and spoke.
        Constants.OpStackAddresses memory opStack = getOpStackAddresses(chainId, opChainId);

        vm.startBroadcast(deployerPrivateKey);

        OP_Adapter opAdapter = new OP_Adapter(
            WETH9Interface(weth), // L1 WETH
            IERC20(usdc), // L1 USDC
            opStack.L1CrossDomainMessenger, // L1 Cross Domain Messenger
            IL1StandardBridge(opStack.L1StandardBridge), // L1 Standard Bridge
            IOpUSDCBridgeAdapter(opStack.L1OpUSDCBridgeAdapter), // Circle Bridged USDC Adapter (non-CCTP).
            ITokenMessenger(cctpTokenMessenger), // CCTP Token Messenger
            cctpDomain
        );

        // Log the deployed addresses
        console.log("Chain ID:", chainId);
        console.log("OP_Adapter deployed to:", address(opAdapter));
        console.log("L1 WETH:", weth);
        console.log("L1 USDC:", usdc);
        console.log("L1 Cross Domain Messenger:", opStack.L1CrossDomainMessenger);
        console.log("L1 Standard Bridge:", opStack.L1StandardBridge);
        console.log("CCTP Token Messenger:", cctpV2TokenMessenger);
        console.log("CCTP Domain:", cctpDomain);

        vm.stopBroadcast();
    }
}
