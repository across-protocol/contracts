// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Script } from "forge-std/Script.sol";
import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";
import { Ethereum_SpokePool } from "../contracts/Ethereum_SpokePool.sol";
import { WETH9Interface } from "../contracts/external/interfaces/WETH9Interface.sol";
import { DeploymentUtils } from "./utils/DeploymentUtils.sol";

// How to run:
// 1. `source .env` where `.env` has MNEMONIC="x x x ... x" and HUBPOOL_ADDRESS="0x..." entries
// 2. forge script script/007DeployEthereumSpokePool.s.sol:DeployEthereumSpokePool --rpc-url $NODE_URL_1 -vvvv
// 3. Verify the above works in simulation mode.
// 4. Deploy with: forge script script/007DeployEthereumSpokePool.s.sol:DeployEthereumSpokePool --rpc-url $NODE_URL_1 --broadcast --verify

contract DeployEthereumSpokePool is Script, Test, DeploymentUtils {
    function run() external {
        string memory deployerMnemonic = vm.envString("MNEMONIC");
        uint256 deployerPrivateKey = vm.deriveKey(deployerMnemonic, 0);

        // Get deployment information
        DeploymentInfo memory info = getSpokePoolDeploymentInfo(address(0)); // Will use HUBPOOL_ADDRESS from env

        console.log("HubPool address:", info.hubPool);

        // Get the appropriate addresses for this chain
        WETH9Interface weth = getWrappedNativeToken(info.spokeChainId);

        vm.startBroadcast(deployerPrivateKey);

        // Prepare constructor arguments for Ethereum_SpokePool
        bytes memory constructorArgs = abi.encode(
            address(weth), // _weth
            QUOTE_TIME_BUFFER(), // _quoteTimeBuffer
            FILL_DEADLINE_BUFFER() // _fillDeadlineBuffer
        );

        // Initialize deposit counter to very high number of deposits to avoid duplicate deposit ID's
        // with deprecated spoke pool.
        bytes memory initArgs = abi.encodeWithSelector(
            Ethereum_SpokePool.initialize.selector,
            1_000_000, // _initialDepositId
            info.hubPool // _withdrawalRecipient (will be set to deployer)
        );

        // Deploy the proxy
        DeploymentResult memory result = deployNewProxy(
            "Ethereum_SpokePool",
            constructorArgs,
            initArgs,
            true // implementationOnly
        );

        // Log the deployed addresses
        console.log("Chain ID:", info.spokeChainId);
        console.log("Hub Chain ID:", info.hubChainId);
        console.log("HubPool address:", info.hubPool);
        console.log("WETH address:", address(weth));
        console.log("Ethereum_SpokePool proxy deployed to:", result.proxy);
        console.log("Ethereum_SpokePool implementation deployed to:", result.implementation);

        // Transfer ownership to hub pool if this is a new proxy
        if (result.isNewProxy) {
            // TODO: Implement ownership transfer if needed
            console.log("Note: Ownership transfer to hub pool may be required");
        }

        vm.stopBroadcast();
    }
}
