// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.19;

import { Script } from "forge-std/Script.sol";
import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";
import { Linea_SpokePool } from "../contracts/Linea_SpokePool.sol";
import { DeploymentUtils } from "./utils/DeploymentUtils.sol";

// How to run:
// 1. `source .env` where `.env` has MNEMONIC="x x x ... x"
// 2. forge script script/DeployLineaSpokePool.s.sol:DeployLineaSpokePool --rpc-url $NODE_URL_59144 -vvvv
// 3. Verify the above works in simulation mode.
// 4. Deploy with: forge script script/DeployLineaSpokePool.s.sol:DeployLineaSpokePool --rpc-url $NODE_URL_59144 --broadcast --verify

contract DeployLineaSpokePool is Script, Test, DeploymentUtils {
    function run() external {
        string memory deployerMnemonic = vm.envString("MNEMONIC");
        uint256 deployerPrivateKey = vm.deriveKey(deployerMnemonic, 0);

        // Get deployment information
        DeploymentInfo memory info = getSpokePoolDeploymentInfo(address(0));

        // Get the appropriate addresses for this chain
        address wrappedNativeToken = getWrappedNativeToken(info.spokeChainId);

        // Get L2 addresses for Linea
        address lineaMessageService = getL2Address(info.spokeChainId, "lineaMessageService");
        address lineaTokenBridge = getL2Address(info.spokeChainId, "lineaTokenBridge");
        address cctpTokenMessenger = getL2Address(info.spokeChainId, "cctpV2TokenMessenger");

        // Get USDC address for Linea
        address usdcAddress = getUSDCAddress(info.spokeChainId);

        vm.startBroadcast(deployerPrivateKey);

        // Prepare constructor arguments for Linea_SpokePool
        bytes memory constructorArgs = abi.encode(
            wrappedNativeToken, // _wrappedNativeTokenAddress
            QUOTE_TIME_BUFFER(), // _depositQuoteTimeBuffer
            FILL_DEADLINE_BUFFER(), // _fillDeadlineBuffer
            usdcAddress, // _l2Usdc
            cctpTokenMessenger // _cctpTokenMessenger
        );

        // Initialize deposit counter to very high number of deposits to avoid duplicate deposit ID's
        // with deprecated spoke pool.
        // Set hub pool as cross domain admin since it delegatecalls the Adapter logic.
        bytes memory initArgs = abi.encodeWithSelector(
            Linea_SpokePool.initialize.selector,
            1_000_000, // _initialDepositId
            lineaMessageService, // _l2MessageService
            lineaTokenBridge, // _l2TokenBridge
            info.hubPool, // _crossDomainAdmin
            info.hubPool // _withdrawalRecipient
        );

        // Deploy the proxy
        DeploymentResult memory result = deployNewProxy(
            "Linea_SpokePool",
            constructorArgs,
            initArgs,
            true // implementationOnly
        );

        // Log the deployed addresses
        console.log("Chain ID:", info.spokeChainId);
        console.log("Hub Chain ID:", info.hubChainId);
        console.log("HubPool address:", info.hubPool);
        console.log("Wrapped Native Token address:", wrappedNativeToken);
        console.log("USDC address:", usdcAddress);
        console.log("Linea Message Service:", lineaMessageService);
        console.log("Linea Token Bridge:", lineaTokenBridge);
        console.log("CCTP Token Messenger:", cctpTokenMessenger);
        console.log("Linea_SpokePool proxy deployed to:", result.proxy);
        console.log("Linea_SpokePool implementation deployed to:", result.implementation);

        console.log("QUOTE_TIME_BUFFER()", QUOTE_TIME_BUFFER());
        console.log("FILL_DEADLINE_BUFFER()", FILL_DEADLINE_BUFFER());

        vm.stopBroadcast();
    }
}
