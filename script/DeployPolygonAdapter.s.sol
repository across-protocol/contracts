// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Script } from "forge-std/Script.sol";
import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";
import { IERC20 } from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";
import { Polygon_Adapter } from "../contracts/chain-adapters/Polygon_Adapter.sol";
import { Constants } from "./utils/Constants.sol";
import { WETH9Interface } from "../contracts/external/interfaces/WETH9Interface.sol";
import { ITokenMessenger } from "../contracts/external/interfaces/CCTPInterfaces.sol";
import { IRootChainManager, IFxStateSender, DepositManager } from "../contracts/chain-adapters/Polygon_Adapter.sol";

// How to run:
// 1. `source .env` where `.env` has MNEMONIC="x x x ... x" and ETHERSCAN_API_KEY="x" entries
// 2. forge script script/009DeployPolygonAdapter.s.sol:DeployPolygonAdapter --rpc-url $NODE_URL_1 -vvvv
// 3. Verify the above works in simulation mode.
// 4. Deploy on mainnet by adding --broadcast --verify flags.
// 5. forge script script/009DeployPolygonAdapter.s.sol:DeployPolygonAdapter --rpc-url $NODE_URL_1 --broadcast --verify -vvvv

contract DeployPolygonAdapter is Script, Test, Constants {
    function run() external {
        string memory deployerMnemonic = vm.envString("MNEMONIC");
        uint256 deployerPrivateKey = vm.deriveKey(deployerMnemonic, 0);

        // Get the current chain ID
        uint256 chainId = block.chainid;

        // Verify this is being deployed on Ethereum mainnet or Sepolia
        require(
            chainId == getChainId("MAINNET") || chainId == getChainId("SEPOLIA"),
            "Polygon_Adapter should only be deployed on Ethereum mainnet or Sepolia"
        );

        // Determine the spoke chain ID (Polygon mainnet or testnet)
        uint256 spokeChainId;
        if (chainId == getChainId("MAINNET")) {
            spokeChainId = getChainId("POLYGON");
        } else {
            spokeChainId = getChainId("POLYGON_AMOY");
        }

        // Get OFT destination endpoint ID and fee cap
        uint32 oftDstEid = uint32(getOftEid(spokeChainId));
        uint256 oftFeeCap = 1e18; // 1 eth transfer fee cap

        // Get L1 addresses for this chain
        Constants.L1Addresses memory l1Addresses = getL1Addresses(chainId);

        vm.startBroadcast(deployerPrivateKey);

        // Deploy Polygon_Adapter with constructor parameters
        Polygon_Adapter polygonAdapter = new Polygon_Adapter(
            IRootChainManager(l1Addresses.polygonRootChainManager),
            IFxStateSender(l1Addresses.polygonFxRoot),
            DepositManager(l1Addresses.polygonDepositManager),
            l1Addresses.polygonERC20Predicate,
            getWmaticAddress(chainId),
            WETH9Interface(getWETHAddress(chainId)),
            IERC20(getUSDCAddress(chainId)),
            ITokenMessenger(l1Addresses.cctpV2TokenMessenger),
            l1Addresses.adapterStore, // This might need to be deployed first or set to address(0)
            oftDstEid,
            oftFeeCap
        );

        // Log the deployed addresses
        console.log("Chain ID:", chainId);
        console.log("Polygon_Adapter deployed to:", address(polygonAdapter));
        console.log("L1 Polygon Root Chain Manager:", l1Addresses.polygonRootChainManager);
        console.log("L1 Polygon Fx Root:", l1Addresses.polygonFxRoot);
        console.log("L1 Polygon Deposit Manager:", l1Addresses.polygonDepositManager);
        console.log("L1 Polygon ERC20 Predicate:", l1Addresses.polygonERC20Predicate);
        console.log("MATIC Address:", getWmaticAddress(chainId));
        console.log("WETH Address:", getWETHAddress(chainId));
        console.log("USDC Address:", getUSDCAddress(chainId));
        console.log("CCTP Token Messenger:", l1Addresses.cctpV2TokenMessenger);
        console.log("Adapter Store:", l1Addresses.adapterStore);
        console.log("OFT Destination EID:", oftDstEid);
        console.log("OFT Fee Cap:", oftFeeCap);

        vm.stopBroadcast();
    }
}
