// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Script } from "forge-std/Script.sol";
import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";
import { Universal_Adapter } from "../contracts/chain-adapters/Universal_Adapter.sol";
import { HubPoolStore } from "../contracts/chain-adapters/utilities/HubPoolStore.sol";
import { Constants } from "./utils/Constants.sol";
import { IERC20 } from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";
import { ITokenMessenger } from "../contracts/external/interfaces/CCTPInterfaces.sol";
import { WETH9Interface } from "../contracts/external/interfaces/WETH9Interface.sol";

// How to run:
// 1. `source .env` where `.env` has MNEMONIC="x x x ... x" and ETHERSCAN_API_KEY="x" entries
// 2. forge script script/110DeployUniversalAdapter.s.sol:DeployUniversalAdapter --sig "run(string)" <DEST_CHAIN_NAME e.g. MONAD> --rpc-url $NODE_URL_1 -vvvv
// 3. Verify the above works in simulation mode.
// 4. Deploy on mainnet by adding --broadcast --verify flags.
// 5. forge script script/110DeployUniversalAdapter.s.sol:DeployUniversalAdapter --sig "run(string)" MONAD --rpc-url $NODE_URL_1 --broadcast --verify -vvvv

contract DeployUniversalAdapter is Script, Test, Constants {
    function run() external pure {
        revert("Not implemented, see script for run instructions");
    }
    function run(string calldata destinationChainName) external {
        string memory deployerMnemonic = vm.envString("MNEMONIC");
        uint256 deployerPrivateKey = vm.deriveKey(deployerMnemonic, 0);

        // Get the current chain ID
        uint256 chainId = block.chainid;

        // Verify this is being deployed on Ethereum mainnet or Sepolia
        require(
            chainId == getChainId("MAINNET") || chainId == getChainId("SEPOLIA"),
            "Universal_Adapter should only be deployed on Ethereum mainnet or Sepolia"
        );

        uint256 destinationChainId = getChainId(destinationChainName);
        bool hasCctpDomain = hasCctpDomain(destinationChainId);
        address cctpTokenMessenger = hasCctpDomain ? getL1Addresses(chainId).cctpV2TokenMessenger : address(0);
        uint32 cctpDomainId = hasCctpDomain ? uint32(getCircleDomainId(destinationChainId)) : 4294967295; // 2^32 - 1

        uint256 oftFeeCap = 1 ether;

        vm.startBroadcast(deployerPrivateKey);

        // Deploy Universal_Adapter with constructor parameters
        Universal_Adapter universalAdapter = new Universal_Adapter(
            HubPoolStore(getL1Addresses(chainId).hubPoolStore),
            IERC20(getUSDCAddress(chainId)),
            ITokenMessenger(cctpTokenMessenger),
            cctpDomainId,
            getL1Addresses(chainId).adapterStore,
            uint32(getOftEid(destinationChainId)),
            oftFeeCap
        );

        // Log the deployed addresses
        console.log("Chain ID:", chainId);
        console.log("Universal_Adapter deployed to:", address(universalAdapter));
        console.log("L1 HubPoolStore:", getL1Addresses(chainId).hubPoolStore);
        console.log("L1 AdapterStore:", getL1Addresses(chainId).adapterStore);
        console.log("L1 USDC:", getUSDCAddress(chainId));
        console.log("CCTP Token Messenger:", cctpTokenMessenger);
        console.log("CCTP Domain ID:", cctpDomainId);
        console.log("OFT Destination EID:", getOftEid(destinationChainId));
        console.log("OFT Fee Cap:", oftFeeCap);

        vm.stopBroadcast();
    }
}
