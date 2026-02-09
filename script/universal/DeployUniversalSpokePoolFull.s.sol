// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Script } from "forge-std/Script.sol";
import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";
import { Universal_SpokePool } from "../../contracts/Universal_SpokePool.sol";
import { DeploymentUtils } from "../utils/DeploymentUtils.sol";
import { ITokenMessenger } from "../../contracts/external/interfaces/CCTPInterfaces.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { DeploySP1Helios } from "./DeploySP1Helios.s.sol";

/// @title DeployUniversalSpokePoolFull
/// @notice Combined deployment script that deploys SP1Helios + Universal_SpokePool and transfers admin roles.
/// @dev This script replaces the manual 4-step process (see README.md) with a single command.
///      It composes DeploySP1Helios (which handles genesis binary download, checksum verification,
///      and SP1Helios deployment) with the Universal_SpokePool proxy deployment and SP1Helios
///      admin role transfer.
///
/// How to run:
/// 1. Set environment variables in .env (same as both individual scripts combined):
///    MNEMONIC, SP1_RELEASE, SP1_PROVER_MODE, SP1_VERIFIER_ADDRESS, SP1_STATE_UPDATERS,
///    SP1_VKEY_UPDATER, SP1_CONSENSUS_RPCS_LIST
/// 2. Simulate:
///    forge script script/universal/DeployUniversalSpokePoolFull.s.sol:DeployUniversalSpokePoolFull \
///      --sig "run(uint256)" <OFT_FEE_CAP> --rpc-url <RPC_URL> --ffi -vvvv
/// 3. Deploy:
///    forge script script/universal/DeployUniversalSpokePoolFull.s.sol:DeployUniversalSpokePoolFull \
///      --sig "run(uint256)" <OFT_FEE_CAP> --rpc-url <RPC_URL> --broadcast --verify \
///      --etherscan-api-key <API_KEY> --ffi -vvvv
contract DeployUniversalSpokePoolFull is Script, Test, DeploymentUtils {
    function run() external pure {
        revert("Usage: forge script ... --sig 'run(uint256)' <OFT_FEE_CAP>");
    }

    function run(uint256 oftFeeCap) external {
        // Step 1: Deploy SP1Helios via the existing script (handles its own broadcast).
        DeploySP1Helios deploySP1Helios = new DeploySP1Helios();
        address helios = deploySP1Helios.run();

        // Step 2: Deploy Universal_SpokePool and transfer SP1Helios admin role.
        string memory deployerMnemonic = vm.envString("MNEMONIC");
        uint256 deployerPrivateKey = vm.deriveKey(deployerMnemonic, 0);
        address deployer = vm.addr(deployerPrivateKey);

        DeploymentInfo memory info = getSpokePoolDeploymentInfo(address(0));
        address wrappedNativeToken = getWrappedNativeToken(info.spokeChainId);
        address usdcAddress = getUSDCAddress(info.spokeChainId);

        vm.startBroadcast(deployerPrivateKey);

        uint256 heliosAdminBufferUpdateSeconds = 1 days;
        address l1HubPoolStore = getL1Addresses(info.hubChainId).hubPoolStore;

        bool _hasCctpDomain = hasCctpDomain(info.spokeChainId);
        address cctpTokenMessenger = _hasCctpDomain
            ? getL2Address(info.spokeChainId, "cctpV2TokenMessenger")
            : address(0);
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
            1, // _initialDepositId
            info.hubPool, // _crossDomainAdmin
            info.hubPool // _withdrawalRecipient
        );

        DeploymentResult memory result = deployNewProxy(
            "Universal_SpokePool",
            constructorArgs,
            initArgs,
            true // implementationOnly
        );

        // Transfer SP1Helios DEFAULT_ADMIN_ROLE from deployer to SpokePool.
        IAccessControl(helios).grantRole(0x00, result.proxy);
        IAccessControl(helios).renounceRole(0x00, deployer);

        vm.stopBroadcast();

        // Log all addresses and configuration.
        console.log("=== DeployUniversalSpokePoolFull Complete ===");
        console.log("Chain ID:", info.spokeChainId);
        console.log("Hub Chain ID:", info.hubChainId);
        console.log("HubPool address:", info.hubPool);
        console.log("SP1Helios address:", helios);
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
        console.log("SP1Helios DEFAULT_ADMIN_ROLE transferred to SpokePool");

        console.log("");
        console.log("NOTE: Run 'yarn extract-addresses' after this script completes to update deployed-addresses.json");
    }
}
