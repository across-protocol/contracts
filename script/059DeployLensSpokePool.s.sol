// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Script } from "forge-std/Script.sol";
import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";
import { Lens_SpokePool } from "../contracts/Lens_SpokePool.sol";
import { ZkSync_SpokePool } from "../contracts/ZkSync_SpokePool.sol";
import { WETH9Interface } from "../contracts/external/interfaces/WETH9Interface.sol";
import { DeploymentUtils } from "./utils/DeploymentUtils.sol";

// How to run:
// 1. `source .env` where `.env` has MNEMONIC="x x x ... x"
// 2. forge script script/059DeployLensSpokePool.s.sol:DeployLensSpokePool --rpc-url $NODE_URL_1 -vvvv
// 3. Verify the above works in simulation mode.
// 4. Deploy with:
//        forge script script/059DeployLensSpokePool.s.sol:DeployLensSpokePool --rpc-url \
//        $NODE_URL_1 --broadcast --verify --verifier blockscout --verifier-url https://verify.lens.xyz/contract_verification

contract DeployLensSpokePool is Script, Test, DeploymentUtils {
    function run() external {
        string memory deployerMnemonic = vm.envString("MNEMONIC");
        uint256 deployerPrivateKey = vm.deriveKey(deployerMnemonic, 0);

        // Get deployment information
        DeploymentInfo memory info = getSpokePoolDeploymentInfo(address(0));

        console.log("HubPool address:", info.hubPool);

        // Get the appropriate addresses for this chain
        address wgho = getWghoAddress(info.spokeChainId);

        // Get L2 addresses for Lens
        address zkErc20Bridge = getL2Address(info.spokeChainId, "zkErc20Bridge");
        address zkUSDCBridge = getL2Address(info.spokeChainId, "zkUSDCBridge");
        address cctpTokenMessenger = getL2Address(info.spokeChainId, "cctpTokenMessenger");

        // Get USDC address - similar logic to the original script
        address usdcAddress = address(0);
        if (zkUSDCBridge != address(0) || cctpTokenMessenger != address(0)) {
            // Only one should be set, not both
            require(
                (zkUSDCBridge != address(0)) != (cctpTokenMessenger != address(0)),
                "Only one of zkUSDCBridge and cctpTokenMessenger should be set"
            );
            usdcAddress = getUSDCAddress(info.spokeChainId);
        }

        vm.startBroadcast(deployerPrivateKey);

        // Prepare constructor arguments for Lens_SpokePool
        bytes memory constructorArgs = abi.encode(
            wgho, // _wrappedNativeTokenAddress
            usdcAddress, // _circleUSDC
            zkUSDCBridge, // _zkUSDCBridge
            cctpTokenMessenger, // _cctpTokenMessenger
            QUOTE_TIME_BUFFER(), // _depositQuoteTimeBuffer
            FILL_DEADLINE_BUFFER() // _fillDeadlineBuffer
        );

        // Initialize deposit counter to 0 as per original script
        // Set hub pool as cross domain admin since it delegatecalls the Adapter logic.
        bytes memory initArgs = abi.encodeWithSelector(
            // For some reason, the ZkSync_SpokePool.initialize selector is not working.
            ZkSync_SpokePool.initialize.selector,
            0, // _initialDepositId
            zkErc20Bridge, // _zkErc20Bridge
            info.hubPool, // _crossDomainAdmin
            info.hubPool // _withdrawalRecipient
        );

        // Deploy the proxy
        DeploymentResult memory result = deployNewProxy(
            "Lens_SpokePool",
            constructorArgs,
            initArgs,
            true // implementationOnly
        );

        // Log the deployed addresses
        console.log("Chain ID:", info.spokeChainId);
        console.log("Hub Chain ID:", info.hubChainId);
        console.log("HubPool address:", info.hubPool);
        console.log("WGHO address:", address(wgho));
        console.log("USDC address:", usdcAddress);
        console.log("zkErc20Bridge:", zkErc20Bridge);
        console.log("zkUSDCBridge:", zkUSDCBridge);
        console.log("cctpTokenMessenger:", cctpTokenMessenger);
        console.log("Lens_SpokePool proxy deployed to:", result.proxy);
        console.log("Lens_SpokePool implementation deployed to:", result.implementation);

        console.log("QUOTE_TIME_BUFFER()", QUOTE_TIME_BUFFER());
        console.log("FILL_DEADLINE_BUFFER()", FILL_DEADLINE_BUFFER());

        vm.stopBroadcast();
    }
}
