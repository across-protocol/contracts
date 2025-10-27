// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Script } from "forge-std/Script.sol";
import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";
import { OP_SpokePool } from "../contracts/OP_SpokePool.sol";
import { DeploymentUtils } from "./utils/DeploymentUtils.sol";

// How to run:
// 1. `source .env` where `.env` has MNEMONIC="x x x ... x"
// 2. forge script script/025DeployOPSpokePool.s.sol:DeployOPSpokePool --rpc-url $NODE_URL_1 -vvvv
// 3. Verify the above works in simulation mode.
// 4. Deploy with:
//        forge script script/025DeployOPSpokePool.s.sol:DeployOPSpokePool --rpc-url \
//        $NODE_URL_1 --broadcast --verify --verifier blockscout --verifier-url https://explorer.mode.network/api

contract DeployOPSpokePool is Script, Test, DeploymentUtils {
    function run() external {
        string memory deployerMnemonic = vm.envString("MNEMONIC");
        uint256 deployerPrivateKey = vm.deriveKey(deployerMnemonic, 0);

        // Get deployment information
        DeploymentInfo memory info = getSpokePoolDeploymentInfo(address(0));

        // Get the appropriate addresses for this chain
        address weth = getWrappedNativeToken(info.spokeChainId);
        address cctpTokenMessenger = getL2Address(info.spokeChainId, "cctpV2TokenMessenger");
        address l2Usdc = getUSDCAddress(info.spokeChainId);

        vm.startBroadcast(deployerPrivateKey);

        // Prepare constructor arguments for OP_SpokePool
        bytes memory constructorArgs = abi.encode(
            weth, // _wrappedNativeTokenAddress
            QUOTE_TIME_BUFFER(), // _depositQuoteTimeBuffer
            FILL_DEADLINE_BUFFER(), // _fillDeadlineBuffer
            l2Usdc, // _l2Usdc
            cctpTokenMessenger // _cctpTokenMessenger
        );

        // Initialize deposit counter to 1
        // Set hub pool as cross domain admin since it delegatecalls the Adapter logic.
        bytes memory initArgs = abi.encodeWithSelector(
            OP_SpokePool.initialize.selector,
            // Note: If this is a re-deployment of the spoke pool proxy, set this to a very high number of
            // deposits to avoid duplicate deposit IDs with deprecated spoke pool. Should be set to 1 otherwise.
            1_000_000, // _initialDepositId
            info.hubPool, // _crossDomainAdmin
            info.hubPool // _withdrawalRecipient
        );

        // Deploy the proxy
        DeploymentResult memory result = deployNewProxy(
            "OP_SpokePool",
            constructorArgs,
            initArgs,
            false // implementationOnly
        );

        // Log the deployed addresses
        console.log("Chain ID:", info.spokeChainId);
        console.log("Hub Chain ID:", info.hubChainId);
        console.log("HubPool address:", info.hubPool);
        console.log("WETH address:", weth);
        console.log("OP_SpokePool proxy deployed to:", result.proxy);
        console.log("OP_SpokePool implementation deployed to:", result.implementation);

        console.log("QUOTE_TIME_BUFFER()", QUOTE_TIME_BUFFER());
        console.log("FILL_DEADLINE_BUFFER()", FILL_DEADLINE_BUFFER());

        vm.stopBroadcast();
    }
}
