// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Script } from "forge-std/Script.sol";
import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";
import { Universal_SpokePool } from "../contracts/Universal_SpokePool.sol";
import { DeploymentUtils } from "./utils/DeploymentUtils.sol";
import { ITokenMessenger } from "../contracts/external/interfaces/CCTPInterfaces.sol";

// How to run:
// 1. `source .env` where `.env` has MNEMONIC="x x x ... x"
// 2. forge script script/111DeployUniversalSpokePool.s.sol:DeployUniversalSpokePool --sig "run(uint256)" <OFT_FEE_CAP> --rpc-url $NODE_URL_143 -vvvv
// 3. Verify the above works in simulation mode.
// 4. Deploy with:
//        forge script script/110DeployUniversalAdapter.s.sol:DeployUniversalAdapter --sig "run(uint256)" <OFT_FEE_CAP e.g. 78000> --rpc-url \
//        $NODE_URL_143 --broadcast --verifier @todo --verifier-url @todo

contract DeployUniversalSpokePool is Script, Test, DeploymentUtils {
    function run() external pure {
        revert("Not implemented, see script for run instructions");
    }
    function run(uint256 oftFeeCap) external {
        string memory deployerMnemonic = vm.envString("MNEMONIC");
        uint256 deployerPrivateKey = vm.deriveKey(deployerMnemonic, 0);

        // Get deployment information
        DeploymentInfo memory info = getSpokePoolDeploymentInfo(address(0));

        // Get the appropriate addresses for this chain
        address wrappedNativeToken = getWrappedNativeToken(info.spokeChainId);

        // Get USDC address for this chain
        address usdcAddress = getUSDCAddress(info.spokeChainId);

        vm.startBroadcast(deployerPrivateKey);

        uint256 heliosAdminBufferUpdateSeconds = 1 days;
        address helios = getL2Address(info.spokeChainId, "helios");
        address l1HubPoolStore = getL1Addresses(info.hubChainId).hubPoolStore;

        bool hasCctpDomain = hasCctpDomain(info.spokeChainId);
        address cctpTokenMessenger = hasCctpDomain
            ? getL2Address(info.spokeChainId, "cctpV2TokenMessenger")
            : address(0);
        uint32 oftDstEid = uint32(getOftEid(info.hubChainId));

        // Prepare constructor arguments for Universal_SpokePool
        bytes memory constructorArgs = abi.encode(
            heliosAdminBufferUpdateSeconds,
            helios,
            l1HubPoolStore,
            wrappedNativeToken,
            QUOTE_TIME_BUFFER(), // _depositQuoteTimeBuffer
            FILL_DEADLINE_BUFFER(), // _fillDeadlineBuffer
            usdcAddress,
            cctpTokenMessenger,
            oftDstEid,
            oftFeeCap
        );

        // Initialize deposit counter to 1
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
        console.log("Helios address:", helios);
        console.log("L1 HubPoolStore address:", l1HubPoolStore);
        console.log("Wrapped Native Token address:", wrappedNativeToken);
        console.log("USDC address:", usdcAddress);
        console.log("CCTP Token Messenger:", cctpTokenMessenger);
        console.log("OFT DST EID:", oftDstEid);
        console.log("OFT Fee Cap:", oftFeeCap);
        console.log("Universal_SpokePool proxy deployed to:", result.proxy);
        console.log("Universal_SpokePool implementation deployed to:", result.implementation);

        console.log("QUOTE_TIME_BUFFER()", QUOTE_TIME_BUFFER());
        console.log("FILL_DEADLINE_BUFFER()", FILL_DEADLINE_BUFFER());

        vm.stopBroadcast();
    }
}
