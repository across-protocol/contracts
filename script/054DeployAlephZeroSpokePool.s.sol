// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.19;

import { Script } from "forge-std/Script.sol";
import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";
import { AlephZero_SpokePool } from "../contracts/AlephZero_SpokePool.sol";
import { Arbitrum_SpokePool } from "../contracts/Arbitrum_SpokePool.sol";
import { WETH9Interface } from "../contracts/external/interfaces/WETH9Interface.sol";
import { DeploymentUtils } from "./utils/DeploymentUtils.sol";

// How to run:
// 1. `source .env` where `.env` has MNEMONIC="x x x ... x"
// 2. forge script script/054DeployAlephZeroSpokePool.s.sol:DeployAlephZeroSpokePool --rpc-url $NODE_URL_1 -vvvv
// 3. Verify the above works in simulation mode.
// 4. Deploy with: forge script script/054DeployAlephZeroSpokePool.s.sol:DeployAlephZeroSpokePool --rpc-url $NODE_URL_1 --broadcast --verify

contract DeployAlephZeroSpokePool is Script, Test, DeploymentUtils {
    function run() external {
        string memory deployerMnemonic = vm.envString("MNEMONIC");
        uint256 deployerPrivateKey = vm.deriveKey(deployerMnemonic, 0);

        // Get deployment information
        DeploymentInfo memory info = getSpokePoolDeploymentInfo(address(0));

        console.log("HubPool address:", info.hubPool);

        // Get the appropriate addresses for this chain
        // TODO: Move this to constants.json
        address wazero = 0xb7Da55D7040ef9C887e20374D76A88F93A59119E;

        // Get L2 addresses for AlephZero
        address l2GatewayRouter = getL2Address(info.spokeChainId, "l2GatewayRouter");

        vm.startBroadcast(deployerPrivateKey);

        // Prepare constructor arguments for AlephZero_SpokePool
        bytes memory constructorArgs = abi.encode(
            wazero, // _wrappedNativeTokenAddress
            QUOTE_TIME_BUFFER(), // _depositQuoteTimeBuffer
            FILL_DEADLINE_BUFFER(), // _fillDeadlineBuffer
            address(0), // _l2Usdc
            address(0), // _cctpTokenMessenger
            uint32(0), // _oftDstEid
            uint256(0) // _oftFeeCap
        );

        // Initialize deposit counter to 0 as per original script
        // Set hub pool as cross domain admin since it delegatecalls the Adapter logic.
        bytes memory initArgs = abi.encodeWithSelector(
            // For some reason, the Arbitrum_SpokePool.initialize selector is not working.
            Arbitrum_SpokePool.initialize.selector,
            0, // _initialDepositId (set to 0 as per original script)
            l2GatewayRouter, // _l2GatewayRouter
            info.hubPool, // _crossDomainAdmin
            info.hubPool // _withdrawalRecipient
        );

        // Deploy the proxy
        DeploymentResult memory result = deployNewProxy(
            "AlephZero_SpokePool",
            constructorArgs,
            initArgs,
            true // implementationOnly
        );

        // Log the deployed addresses
        console.log("Chain ID:", info.spokeChainId);
        console.log("Hub Chain ID:", info.hubChainId);
        console.log("HubPool address:", info.hubPool);
        console.log("WAZERO address:", address(wazero));
        console.log("L2 Gateway Router:", l2GatewayRouter);
        console.log("AlephZero_SpokePool proxy deployed to:", result.proxy);
        console.log("AlephZero_SpokePool implementation deployed to:", result.implementation);

        console.log("QUOTE_TIME_BUFFER()", QUOTE_TIME_BUFFER());
        console.log("FILL_DEADLINE_BUFFER()", FILL_DEADLINE_BUFFER());

        vm.stopBroadcast();
    }
}
