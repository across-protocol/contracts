// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Script } from "forge-std/Script.sol";
import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";
import { Arbitrum_SpokePool } from "../contracts/Arbitrum_SpokePool.sol";
import { WETH9Interface } from "../contracts/external/interfaces/WETH9Interface.sol";
import { DeploymentUtils } from "./utils/DeploymentUtils.sol";

// How to run:
// 1. `source .env` where `.env` has MNEMONIC="x x x ... x"
// 2. forge script script/008DeployArbitrumSpokePool.s.sol:DeployArbitrumSpokePool --rpc-url $NODE_URL_1 -vvvv
// 3. Verify the above works in simulation mode.
// 4. Deploy with: forge script script/008DeployArbitrumSpokePool.s.sol:DeployArbitrumSpokePool --rpc-url $NODE_URL_1 --broadcast --verify

contract DeployArbitrumSpokePool is Script, Test, DeploymentUtils {
    function run() external {
        string memory deployerMnemonic = vm.envString("MNEMONIC");
        uint256 deployerPrivateKey = vm.deriveKey(deployerMnemonic, 0);

        // Get deployment information
        DeploymentInfo memory info = getSpokePoolDeploymentInfo(address(0));

        console.log("HubPool address:", info.hubPool);

        // Get the appropriate addresses for this chain
        WETH9Interface weth = getWrappedNativeToken(info.spokeChainId);

        // Get L2 addresses for Arbitrum
        address l2GatewayRouter = getL2Address(info.spokeChainId, "l2GatewayRouter");
        address cctpTokenMessenger = getL2Address(info.spokeChainId, "cctpTokenMessenger");

        vm.startBroadcast(deployerPrivateKey);

        // Prepare constructor arguments for Arbitrum_SpokePool
        bytes memory constructorArgs = abi.encode(
            address(weth), // _weth
            QUOTE_TIME_BUFFER(), // _quoteTimeBuffer
            FILL_DEADLINE_BUFFER(), // _fillDeadlineBuffer
            getUSDCAddress(info.spokeChainId), // _usdc
            cctpTokenMessenger, // _cctpTokenMessenger
            getOftEid(info.hubChainId), // _oftDstEid
            1 ether // _oftFeeCap
        );

        // Initialize deposit counter to very high number of deposits to avoid duplicate deposit ID's
        // with deprecated spoke pool.
        bytes memory initArgs = abi.encodeWithSelector(
            Arbitrum_SpokePool.initialize.selector,
            1_000_000, // _initialDepositId
            l2GatewayRouter, // _l2GatewayRouter
            info.hubPool, // _crossDomainAdmin
            info.hubPool // _hubPool
        );

        // Deploy the proxy
        DeploymentResult memory result = deployNewProxy(
            "Arbitrum_SpokePool",
            constructorArgs,
            initArgs,
            true // implementationOnly
        );

        // Log the deployed addresses
        console.log("Chain ID:", info.spokeChainId);
        console.log("Hub Chain ID:", info.hubChainId);
        console.log("HubPool address:", info.hubPool);
        console.log("WETH address:", address(weth));
        console.log("L2 Gateway Router:", l2GatewayRouter);
        console.log("CCTP Token Messenger:", cctpTokenMessenger);
        console.log("USDC address:", getUSDCAddress(info.spokeChainId));
        console.log("Arbitrum_SpokePool proxy deployed to:", result.proxy);
        console.log("Arbitrum_SpokePool implementation deployed to:", result.implementation);

        console.log("QUOTE_TIME_BUFFER()", QUOTE_TIME_BUFFER());
        console.log("FILL_DEADLINE_BUFFER()", FILL_DEADLINE_BUFFER());
        console.log("OFT EID", getOftEid(info.hubChainId));

        vm.stopBroadcast();
    }
}
