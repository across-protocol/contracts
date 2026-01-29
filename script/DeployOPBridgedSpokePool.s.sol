// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Script } from "forge-std/Script.sol";
import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";
import { Cher_SpokePool } from "../contracts/Cher_SpokePool.sol";
import { Lisk_SpokePool } from "../contracts/Lisk_SpokePool.sol";
import { DeploymentUtils } from "./utils/DeploymentUtils.sol";

// How to run:
// 1. `source .env` where `.env` has MNEMONIC="x x x ... x"
// 2. forge script script/DeployOPBridgedSpokePool.s.sol:DeployOPBridgedSpokePool --rpc-url $NODE_URL_1 -vvvv
// 3. Verify the above works in simulation mode.
// 4. Deploy with:
//        forge script script/DeployOPBridgedSpokePool.s.sol:DeployOPBridgedSpokePool --rpc-url \
//        $NODE_URL_1 --broadcast --verify --verifier blockscout --verifier-url https://soneium.blockscout.com/api

contract DeployOPBridgedSpokePool is Script, Test, DeploymentUtils {
    function run() external {
        // Get deployment information
        DeploymentInfo memory info = getSpokePoolDeploymentInfo(address(0));

        // One deployment script covers two contracts - basic sanity checks.
        require(info.spokeChainId == 1135 || info.spokeChainId == 1868, "Unsupported chainId");
        require(
            Lisk_SpokePool.initialize.selector == Cher_SpokePool.initialize.selector,
            "Lisk & Soneium SpokePool constructors differ"
        );

        string memory deployerMnemonic = vm.envString("MNEMONIC");
        uint256 deployerPrivateKey = vm.deriveKey(deployerMnemonic, 0);

        string memory spokePool = info.spokeChainId == 1135 ? "Lisk_SpokePool" : "Cher_SpokePool"; // Soneium

        // Get the appropriate addresses for this chain
        address weth = getWrappedNativeToken(info.spokeChainId);

        // Get USDC address for Cher
        address usdcAddress = getUSDCeAddress(info.spokeChainId);

        vm.startBroadcast(deployerPrivateKey);

        // Prepare constructor arguments for SpokePool
        bytes memory constructorArgs = abi.encode(
            weth, // _wrappedNativeTokenAddress
            QUOTE_TIME_BUFFER(), // _depositQuoteTimeBuffer
            FILL_DEADLINE_BUFFER(), // _fillDeadlineBuffer
            usdcAddress, // _l2Usdc (Bridged USDC that's upgradeable to native)
            address(0) // _cctpTokenMessenger (set to zero address as per original script)
        );

        // Initialize deposit counter to 1
        // Set hub pool as cross domain admin since it delegatecalls the Adapter logic.
        bytes memory initArgs = abi.encodeWithSelector(
            Cher_SpokePool.initialize.selector,
            1, // _initialDepositId
            info.hubPool, // _crossDomainAdmin
            info.hubPool // _withdrawalRecipient
        );

        // Deploy the proxy
        DeploymentResult memory result = deployNewProxy(
            spokePool,
            constructorArgs,
            initArgs,
            true // implementationOnly
        );

        // Log the deployed addresses
        console.log("Chain ID:", info.spokeChainId);
        console.log("Hub Chain ID:", info.hubChainId);
        console.log("HubPool address:", info.hubPool);
        console.log("WETH address:", weth);
        console.log("USDC address:", usdcAddress);
        console.log(spokePool, " proxy deployed to:", result.proxy);
        console.log(spokePool, " implementation deployed to:", result.implementation);

        console.log("QUOTE_TIME_BUFFER()", QUOTE_TIME_BUFFER());
        console.log("FILL_DEADLINE_BUFFER()", FILL_DEADLINE_BUFFER());

        vm.stopBroadcast();
    }
}
