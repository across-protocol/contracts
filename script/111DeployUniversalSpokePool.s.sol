// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Script } from "forge-std/Script.sol";
import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";
import { Universal_SpokePool } from "../contracts/Universal_SpokePool.sol";
import { WETH9Interface } from "../contracts/external/interfaces/WETH9Interface.sol";
import { DeploymentUtils } from "./utils/DeploymentUtils.sol";

// How to run:
// 1. `source .env` where `.env` has MNEMONIC="x x x ... x"
// 2. forge script script/111DeployUniversalSpokePool.s.sol:DeployUniversalSpokePool --rpc-url <chain> -vvvv
// 3. Verify the above works in simulation mode.
// 4. Deploy with:
//        forge script script/111DeployUniversalSpokePool.s.sol:DeployUniversalSpokePool --rpc-url <chain> \
//        --broadcast --verify --verifier blockscout --verifier-url <verifier_url>

contract DeployUniversalSpokePool is Script, Test, DeploymentUtils {
    function run() external {
        string memory deployerMnemonic = vm.envString("MNEMONIC");
        uint256 deployerPrivateKey = vm.deriveKey(deployerMnemonic, 0);

        // Get deployment information
        DeploymentInfo memory info = getSpokePoolDeploymentInfo(address(0));

        console.log("HubPool address:", info.hubPool);

        // Get the appropriate addresses for this chain
        WETH9Interface wrappedNativeToken = getWrappedNativeToken(info.spokeChainId);

        // Get OFT destination EID and fee cap
        uint32 oftEid = uint32(getOftEid(info.hubChainId));
        uint256 oftFeeCap = 79.2 ether; // ~79.2 native token fee cap (adjusted for HYPEREVM)

        // Get Helios address for this chain
        address heliosAddress = getDeployedAddress("Helios", info.spokeChainId, false);
        require(heliosAddress != address(0), "Helios address not found for this chain");

        // Get HubPoolStore address for hub chain
        address hubPoolStoreAddress = getDeployedAddress("HubPoolStore", info.hubChainId, false);
        require(hubPoolStoreAddress != address(0), "HubPoolStore address not found for hub chain");

        // Get USDC address for this chain
        address usdcAddress = getUSDCAddress(info.spokeChainId);

        // Get CCTP token messenger for this chain
        address cctpTokenMessenger = getL2Address(info.spokeChainId, "cctpTokenMessenger");

        vm.startBroadcast(deployerPrivateKey);

        // Prepare constructor arguments for Universal_SpokePool
        bytes memory constructorArgs = abi.encode(
            24 * 60 * 60, // _adminUpdateBufferSeconds - 1 day; Helios latest head timestamp must be 1 day old before an admin can force execute a message
            heliosAddress, // _helios
            hubPoolStoreAddress, // _hubPoolStore
            address(wrappedNativeToken), // _wrappedNativeTokenAddress
            QUOTE_TIME_BUFFER(), // _depositQuoteTimeBuffer
            FILL_DEADLINE_BUFFER(), // _fillDeadlineBuffer
            usdcAddress, // _l2Usdc
            cctpTokenMessenger, // _cctpTokenMessenger
            oftEid, // _oftDstEid
            oftFeeCap // _oftFeeCap
        );

        // Initialize deposit counter to 1 as per original script
        // Set hub pool as cross domain admin since it delegatecalls the Adapter logic.
        bytes memory initArgs = abi.encodeWithSelector(
            Universal_SpokePool.initialize.selector,
            1, // _initialDepositId
            info.hubPool, // _crossDomainAdmin
            info.hubPool // _withdrawalRecipient
        );

        // Deploy the proxy
        DeploymentResult memory result = deployNewProxy(
            "Universal_SpokePool",
            constructorArgs,
            initArgs,
            true // implementationOnly
        );

        // Log the deployed addresses
        console.log("Chain ID:", info.spokeChainId);
        console.log("Hub Chain ID:", info.hubChainId);
        console.log("HubPool address:", info.hubPool);
        console.log("Wrapped Native Token address:", address(wrappedNativeToken));
        console.log("USDC address:", usdcAddress);
        console.log("CCTP Token Messenger:", cctpTokenMessenger);
        console.log("Helios address:", heliosAddress);
        console.log("HubPoolStore address:", hubPoolStoreAddress);
        console.log("OFT Destination EID:", oftEid);
        console.log("OFT Fee Cap:", oftFeeCap);
        console.log("Universal_SpokePool proxy deployed to:", result.proxy);
        console.log("Universal_SpokePool implementation deployed to:", result.implementation);

        console.log("QUOTE_TIME_BUFFER()", QUOTE_TIME_BUFFER());
        console.log("FILL_DEADLINE_BUFFER()", FILL_DEADLINE_BUFFER());
        console.log("Admin Update Buffer: 24 hours");

        vm.stopBroadcast();
    }
}
