// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Script } from "forge-std/Script.sol";
import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";
import { Zora_SpokePool } from "../contracts/Zora_SpokePool.sol";
import { WETH9Interface } from "../contracts/external/interfaces/WETH9Interface.sol";
import { DeploymentUtils } from "./utils/DeploymentUtils.sol";

// How to run:
// 1. `source .env` where `.env` has MNEMONIC="x x x ... x"
// 2. forge script script/049DeployZoraSpokePool.s.sol:DeployZoraSpokePool --rpc-url $NODE_URL_1 -vvvv
// 3. Verify the above works in simulation mode.
// 4. Deploy with: forge script script/049DeployZoraSpokePool.s.sol:DeployZoraSpokePool --rpc-url $NODE_URL_1 --broadcast --verify

contract DeployZoraSpokePool is Script, Test, DeploymentUtils {
    function run() external {
        string memory deployerMnemonic = vm.envString("MNEMONIC");
        uint256 deployerPrivateKey = vm.deriveKey(deployerMnemonic, 0);

        // Get deployment information
        DeploymentInfo memory info = getSpokePoolDeploymentInfo(address(0));

        console.log("HubPool address:", info.hubPool);

        // Get the appropriate addresses for this chain
        WETH9Interface weth = getWrappedNativeToken(info.spokeChainId);

        vm.startBroadcast(deployerPrivateKey);

        // Prepare constructor arguments for Zora_SpokePool
        bytes memory constructorArgs = abi.encode(
            address(weth), // _wrappedNativeTokenAddress
            QUOTE_TIME_BUFFER(), // _depositQuoteTimeBuffer
            FILL_DEADLINE_BUFFER(), // _fillDeadlineBuffer
            address(0), // _l2Usdc
            address(0) // _cctpTokenMessenger
        );

        // Initialize deposit counter to 1
        // Set hub pool as cross domain admin since it delegatecalls the Adapter logic.
        bytes memory initArgs = abi.encodeWithSelector(
            Zora_SpokePool.initialize.selector,
            1, // _initialDepositId
            info.hubPool, // _crossDomainAdmin
            info.hubPool // _withdrawalRecipient
        );

        // Deploy the proxy
        DeploymentResult memory result = deployNewProxy(
            "Zora_SpokePool",
            constructorArgs,
            initArgs,
            true // implementationOnly
        );

        // Log the deployed addresses
        console.log("Chain ID:", info.spokeChainId);
        console.log("Hub Chain ID:", info.hubChainId);
        console.log("HubPool address:", info.hubPool);
        console.log("WETH address:", address(weth));
        console.log("Zora_SpokePool proxy deployed to:", result.proxy);
        console.log("Zora_SpokePool implementation deployed to:", result.implementation);

        console.log("QUOTE_TIME_BUFFER()", QUOTE_TIME_BUFFER());
        console.log("FILL_DEADLINE_BUFFER()", FILL_DEADLINE_BUFFER());

        vm.stopBroadcast();
    }
}
