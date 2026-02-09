// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Script } from "forge-std/Script.sol";
import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";
import { DeploymentUtils } from "../utils/DeploymentUtils.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { DeploySP1Helios } from "./DeploySP1Helios.s.sol";
import { DeployUniversalSpokePool } from "./DeployUniversalSpokePool.s.sol";

/// @title DeployUniversalSpokePoolFull
/// @notice Combined deployment script that deploys SP1Helios + Universal_SpokePool and transfers admin roles.
/// @dev This script replaces the manual 4-step process (see README.md) with a single command.
///      It composes DeploySP1Helios and DeployUniversalSpokePool, then transfers the SP1Helios
///      DEFAULT_ADMIN_ROLE from the deployer to the SpokePool.
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
        // Step 1: Deploy SP1Helios (handles its own broadcast internally).
        DeploySP1Helios deploySP1Helios = new DeploySP1Helios();
        address helios = deploySP1Helios.run();

        // Step 2: Deploy Universal_SpokePool and transfer SP1Helios admin role.
        string memory deployerMnemonic = vm.envString("MNEMONIC");
        uint256 deployerPrivateKey = vm.deriveKey(deployerMnemonic, 0);
        address deployer = vm.addr(deployerPrivateKey);

        vm.startBroadcast(deployerPrivateKey);

        DeployUniversalSpokePool deployUSP = new DeployUniversalSpokePool();
        address proxy = deployUSP.deploy(oftFeeCap, helios);

        // Transfer SP1Helios DEFAULT_ADMIN_ROLE from deployer to SpokePool.
        IAccessControl(helios).grantRole(0x00, proxy);
        IAccessControl(helios).renounceRole(0x00, deployer);

        vm.stopBroadcast();

        console.log("=== DeployUniversalSpokePoolFull Complete ===");
        console.log("SP1Helios DEFAULT_ADMIN_ROLE transferred to SpokePool");

        console.log("");
        console.log("NOTE: Run 'yarn extract-addresses' after this script completes to update deployed-addresses.json");
    }
}
