// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Script } from "forge-std/Script.sol";
import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";
import { Polygon_SpokePool } from "../contracts/Polygon_SpokePool.sol";
import { PolygonTokenBridger } from "../contracts/PolygonTokenBridger.sol";
import { DeploymentUtils } from "./utils/DeploymentUtils.sol";

// How to run:
// 1. `source .env` where `.env` has MNEMONIC="x x x ... x"
// 2. forge script script/011DeployPolygonSpokePool.s.sol:DeployPolygonSpokePool --rpc-url $NODE_URL_137 -vvvv
// 3. Verify the above works in simulation mode.
// 4. Deploy with: forge script script/011DeployPolygonSpokePool.s.sol:DeployPolygonSpokePool --rpc-url $NODE_URL_137 --broadcast --verify

contract DeployPolygonSpokePool is Script, Test, DeploymentUtils {
    function run() external {
        string memory deployerMnemonic = vm.envString("MNEMONIC");
        uint256 deployerPrivateKey = vm.deriveKey(deployerMnemonic, 0);

        // Get deployment information
        DeploymentInfo memory info = getSpokePoolDeploymentInfo(address(0));

        // Get the appropriate addresses for this chain
        address wmatic = getWrappedNativeToken(info.spokeChainId);

        // Get L2 addresses for Polygon
        address cctpTokenMessenger = getL2Address(info.spokeChainId, "cctpV2TokenMessenger");

        // Fee cap of 22K POL is roughly equivalent to $5K at current POL price of ~0.23
        uint256 oftFeeCap = 22000 ether;

        vm.startBroadcast(deployerPrivateKey);

        // Prepare constructor arguments for Polygon_SpokePool
        bytes memory constructorArgs = abi.encode(
            wmatic, // _wmatic
            QUOTE_TIME_BUFFER(), // _quoteTimeBuffer
            FILL_DEADLINE_BUFFER(), // _fillDeadlineBuffer
            getUSDCAddress(info.spokeChainId), // _usdc
            cctpTokenMessenger, // _cctpTokenMessenger
            getOftEid(info.hubChainId), // _oftDstEid
            oftFeeCap // _oftFeeCap
        );

        // Initialize deposit counter to very high number of deposits to avoid duplicate deposit ID's
        // with deprecated spoke pool.
        address polygonTokenBridger = 0x0330E9b4D0325cCfF515E81DFbc7754F2a02ac57;
        bytes memory initArgs = abi.encodeWithSelector(
            Polygon_SpokePool.initialize.selector,
            1_000_000, // _initialDepositId
            // The same token bridger must be deployed on mainnet and polygon, so its easier
            // to reuse it.
            PolygonTokenBridger(payable(polygonTokenBridger)), // _polygonTokenBridger
            info.hubPool, // _crossDomainAdmin
            info.hubPool, // _hubPool
            getL2Address(info.spokeChainId, "fxChild") // _fxChild
        );

        // Deploy the proxy
        DeploymentResult memory result = deployNewProxy(
            "Polygon_SpokePool",
            constructorArgs,
            initArgs,
            true // implementationOnly
        );

        // Log the deployed addresses
        console.log("Chain ID:", info.spokeChainId);
        console.log("Hub Chain ID:", info.hubChainId);
        console.log("HubPool address:", info.hubPool);
        console.log("WMATIC address:", wmatic);
        console.log("CCTP Token Messenger:", cctpTokenMessenger);
        console.log("USDC address:", getUSDCAddress(info.spokeChainId));
        console.log("PolygonTokenBridger address:", polygonTokenBridger);
        console.log("FxChild address:", getL2Address(info.spokeChainId, "fxChild"));
        console.log("Polygon_SpokePool proxy deployed to:", result.proxy);
        console.log("Polygon_SpokePool implementation deployed to:", result.implementation);

        console.log("QUOTE_TIME_BUFFER()", QUOTE_TIME_BUFFER());
        console.log("FILL_DEADLINE_BUFFER()", FILL_DEADLINE_BUFFER());
        console.log("OFT EID", getOftEid(info.hubChainId));
        console.log("OFT Fee Cap:", oftFeeCap);

        vm.stopBroadcast();
    }
}
