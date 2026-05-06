// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Script } from "forge-std/Script.sol";
import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";
import { Tron_SpokePool } from "../../contracts/spoke-pools/Tron_SpokePool.sol";
import { Universal_SpokePool } from "../../contracts/spoke-pools/Universal_SpokePool.sol";
import { DeploymentUtils } from "../utils/DeploymentUtils.sol";
import { ITokenMessenger } from "../../contracts/external/interfaces/CCTPInterfaces.sol";

// How to run:
// 1. `source .env` where `.env` has MNEMONIC="x x x ... x"
// 2. forge script script/spoke-pools/DeployTronSpokePool.s.sol:DeployTronSpokePool --sig "run(uint256)" <OFT_FEE_CAP> --rpc-url $NODE_URL_728126428 -vvvv
// 3. Verify the above works in simulation mode.
// 4. Deploy with --broadcast.
//
// Tron_SpokePool inherits from Universal_SpokePool — its constructor signature is identical.
// Tron's deployed SpokePool (chain id 728126428) is a UUPS proxy already initialized; this
// script deploys the new implementation only and the proxy is upgraded via a separate
// cross-domain admin batch from the HubPool.

contract DeployTronSpokePool is Script, Test, DeploymentUtils {
    function run() external pure {
        revert("Not implemented, see script for run instructions");
    }

    function run(uint256 oftFeeCap) external {
        string memory deployerMnemonic = vm.envString("MNEMONIC");
        uint256 deployerPrivateKey = vm.deriveKey(deployerMnemonic, 0);

        DeploymentInfo memory info = getSpokePoolDeploymentInfo(address(0));

        address wrappedNativeToken = getWrappedNativeToken(info.spokeChainId);
        address usdcAddress = getUSDCAddress(info.spokeChainId);

        vm.startBroadcast(deployerPrivateKey);

        uint256 heliosAdminBufferUpdateSeconds = 1 days;
        address helios = getL2Address(info.spokeChainId, "helios");
        address l1HubPoolStore = getL1Addresses(info.hubChainId).hubPoolStore;

        bool hasCctp = hasCctpDomain(info.spokeChainId);
        address cctpTokenMessenger = hasCctp ? getL2Address(info.spokeChainId, "cctpV2TokenMessenger") : address(0);
        uint32 oftDstEid = uint32(getOftEid(info.hubChainId));

        bytes memory constructorArgs = abi.encode(
            heliosAdminBufferUpdateSeconds,
            helios,
            l1HubPoolStore,
            wrappedNativeToken,
            QUOTE_TIME_BUFFER(),
            FILL_DEADLINE_BUFFER(),
            usdcAddress,
            cctpTokenMessenger,
            oftDstEid,
            oftFeeCap
        );

        bytes memory initArgs = abi.encodeWithSelector(
            Universal_SpokePool.initialize.selector,
            1,
            info.hubPool,
            info.hubPool
        );

        DeploymentResult memory result = deployNewProxy("Tron_SpokePool", constructorArgs, initArgs, true);

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
        console.log("Tron_SpokePool proxy:", result.proxy);
        console.log("Tron_SpokePool implementation:", result.implementation);

        vm.stopBroadcast();
    }
}
