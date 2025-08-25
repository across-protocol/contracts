// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Script } from "forge-std/Script.sol";
import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";
import { Scroll_SpokePool } from "../contracts/Scroll_SpokePool.sol";
import { WETH9Interface } from "../contracts/external/interfaces/WETH9Interface.sol";
import { DeploymentUtils } from "./utils/DeploymentUtils.sol";

// How to run:
// 1. `source .env` where `.env` has MNEMONIC="x x x ... x"
// 2. forge script script/027DeployScrollSpokePool.s.sol:DeployScrollSpokePool --rpc-url $NODE_URL_1 -vvvv
// 3. Verify the above works in simulation mode.
// 4. Deploy with: forge script script/027DeployScrollSpokePool.s.sol:DeployScrollSpokePool --rpc-url $NODE_URL_1 --broadcast --verify

contract DeployScrollSpokePool is Script, Test, DeploymentUtils {
    function run() external {
        string memory deployerMnemonic = vm.envString("MNEMONIC");
        uint256 deployerPrivateKey = vm.deriveKey(deployerMnemonic, 0);

        // Get deployment information
        DeploymentInfo memory info = getSpokePoolDeploymentInfo(address(0));

        console.log("HubPool address:", info.hubPool);

        // Get the appropriate addresses for this chain
        WETH9Interface weth = getWrappedNativeToken(info.spokeChainId);

        // Get L2 addresses for Scroll
        address l2GatewayRouter = getL2Address(info.spokeChainId, "scrollERC20GatewayRouter");
        address l2ScrollMessenger = getL2Address(info.spokeChainId, "scrollMessenger");

        vm.startBroadcast(deployerPrivateKey);

        // Prepare constructor arguments for Scroll_SpokePool
        bytes memory constructorArgs = abi.encode(
            address(weth), // _wrappedNativeTokenAddress
            QUOTE_TIME_BUFFER(), // _depositQuoteTimeBuffer
            FILL_DEADLINE_BUFFER() // _fillDeadlineBuffer
        );

        // Initialize deposit counter to very high number of deposits to avoid duplicate deposit ID's
        // with deprecated spoke pool.
        // Set hub pool as cross domain admin since it delegatecalls the Adapter logic.
        bytes memory initArgs = abi.encodeWithSelector(
            Scroll_SpokePool.initialize.selector,
            l2GatewayRouter, // _l2GatewayRouter
            l2ScrollMessenger, // _l2ScrollMessenger
            1_000_000, // _initialDepositId
            info.hubPool, // _crossDomainAdmin
            info.hubPool // _withdrawalRecipient
        );

        // Deploy the proxy
        DeploymentResult memory result = deployNewProxy(
            "Scroll_SpokePool",
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
        console.log("L2 Scroll Messenger:", l2ScrollMessenger);
        console.log("Scroll_SpokePool proxy deployed to:", result.proxy);
        console.log("Scroll_SpokePool implementation deployed to:", result.implementation);

        console.log("QUOTE_TIME_BUFFER()", QUOTE_TIME_BUFFER());
        console.log("FILL_DEADLINE_BUFFER()", FILL_DEADLINE_BUFFER());

        vm.stopBroadcast();
    }
}
