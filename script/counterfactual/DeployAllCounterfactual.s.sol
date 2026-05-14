// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Script } from "forge-std/Script.sol";
import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";
import { CounterfactualConfig } from "./CounterfactualConfig.sol";
import { CounterfactualDeposit } from "../../contracts/periphery/counterfactual/CounterfactualDeposit.sol";
import { CounterfactualDepositFactory } from "../../contracts/periphery/counterfactual/CounterfactualDepositFactory.sol";
import { WithdrawImplementation } from "../../contracts/periphery/counterfactual/WithdrawImplementation.sol";
import { CounterfactualDepositSpokePool } from "../../contracts/periphery/counterfactual/CounterfactualDepositSpokePool.sol";
import { CounterfactualDepositCCTP } from "../../contracts/periphery/counterfactual/CounterfactualDepositCCTP.sol";
import { CounterfactualDepositOFT } from "../../contracts/periphery/counterfactual/CounterfactualDepositOFT.sol";
import { AdminWithdrawManager } from "../../contracts/periphery/counterfactual/AdminWithdrawManager.sol";

// Deploys counterfactual contracts via CREATE2 using the deterministic deployment proxy
// (0x4e59b44847b379578588920cA78FbF26c0B4956C). Each individual deploy script is invoked via ffi
// so broadcast artifacts are recorded in each script's own folder.
//
// CREATE2 addresses are determined by (factory, salt, initCode). Contracts with identical initCode
// across chains (no constructor args, or same constructor args) get the same address everywhere.
// Contracts with chain-specific constructor args get chain-specific addresses.
//
// Under Registry Routes, every counterfactual contract listed below has the SAME deterministic
// address on every EVM chain (assuming the ChainConfig registry has the same address on every
// chain — see DeployChainConfig). Per-chain values (spokePool, src peripheries, source domain,
// src eid, signer, token addresses) live in ChainConfig and are NOT baked into impl bytecode.
//
// Same address across all chains:
//   - CounterfactualDeposit (no constructor args)
//   - CounterfactualDepositFactory (no constructor args)
//   - WithdrawImplementation (no constructor args)
//   - AdminWithdrawManager (same constructor args on all chains)
//   - CounterfactualDepositSpokePool (constructor: registry — same address on every chain)
//   - CounterfactualDepositCCTP    (constructor: registry — same address on every chain)
//   - CounterfactualDepositOFT     (constructor: registry — same address on every chain)
//
// Advantages over nonce-based (CREATE) deployment:
//   - No fresh EOA required — any funded address can deploy
//   - No nonce burning for skipped contracts
//   - No ordering dependency — deploy in any order
//   - Idempotent — already-deployed contracts are auto-skipped
//
// Configuration:
//   - Operational params (signer, ownerAndDirectWithdrawer): script/counterfactual/config.toml
//   - ChainConfig registry: looked up from deployed-addresses.json. Per-chain bridge / token / scalar
//     entries are populated via ChainConfig setters out-of-band (see DESIGN doc), NOT by this script.
//   - AdminWithdrawManager is deployed with deployer as owner/directWithdrawer and signer from
//     config.toml. Role transfers (owner/directWithdrawer) are done directly by this script after
//     all ffi deployments complete, with a safety check that directWithdrawer transferred
//     successfully before transferring ownership
//
// Always deployed:
//   - CounterfactualDeposit, CounterfactualDepositFactory, WithdrawImplementation, AdminWithdrawManager
//
// Optionally deployed (controlled by bool arguments):
//   - CounterfactualDepositSpokePool (deploySpokePool)
//   - CounterfactualDepositCCTP (deployCctp)
//   - CounterfactualDepositOFT (deployOft)
//
// Environment variables:
//   MNEMONIC          - Required. Mnemonic phrase for key derivation.
//
// How to run:
// 1. Edit script/counterfactual/config.toml with signer and ownerAndDirectWithdrawer per chain
// 2. `source .env` where `.env` has MNEMONIC="x x x ... x" and ETHERSCAN_API_KEY="x"
// 3. forge script \
//      script/counterfactual/DeployAllCounterfactual.s.sol:DeployAllCounterfactual \
//      --sig "run(string,bool,bool,bool,bool,bool,string)" <rpcUrl> true true true true true counterfactual \
//      --rpc-url <rpcUrl> --ffi -vvvv
// 4. Verify the logged predicted addresses and forge commands look correct
contract DeployAllCounterfactual is Script, Test, CounterfactualConfig {
    string constant SCRIPT_DIR = "script/counterfactual/";

    /// @param rpcUrl RPC URL for the target chain.
    /// @param deploySpokePool If true, deploy CounterfactualDepositSpokePool.
    /// @param deployCctp If true, deploy CounterfactualDepositCCTP.
    /// @param deployOft If true, deploy CounterfactualDepositOFT.
    /// @param transferRoles If true, transfer AdminWithdrawManager roles to config.toml addresses.
    /// @param broadcast If true, broadcast transactions on-chain.
    /// @param profile Foundry profile to use for sub-script invocations (e.g. "counterfactual").
    function run(
        string calldata rpcUrl,
        bool deploySpokePool,
        bool deployCctp,
        bool deployOft,
        bool transferRoles,
        bool broadcast,
        string calldata profile
    ) external {
        address signer = _loadSigner();
        address registry = _resolveChainConfig();
        if (deploySpokePool || deployCctp || deployOft) {
            require(registry != address(0), "ChainConfig must be deployed before counterfactual impls");
        }

        string memory mnemonic = vm.envString("MNEMONIC");
        uint256 deployerPrivateKey = vm.deriveKey(mnemonic, 0);
        address deployer = vm.addr(deployerPrivateKey);

        // Log predicted addresses upfront so they can be verified before deploying.
        console.log("============================================");
        console.log("Counterfactual Contracts CREATE2 Deployment");
        console.log("============================================");
        console.log("Deployer:  ", deployer);
        console.log("Chain ID:  ", block.chainid);
        console.log("Broadcast: ", broadcast);
        console.log("--------------------------------------------");
        console.log("Resolved parameters:");
        console.log("  Signer (AdminWithdrawManager): ", signer);
        console.log("  ChainConfig registry:          ", registry);
        console.log("  Transfer roles:                ", transferRoles);
        console.log("--------------------------------------------");
        console.log("Predicted addresses:");

        // Predict and log addresses for all contracts being deployed.
        address predictedDeposit = _predictCreate2(bytes32(0), type(CounterfactualDeposit).creationCode);
        address predictedFactory = _predictCreate2(bytes32(0), type(CounterfactualDepositFactory).creationCode);
        address predictedWithdraw = _predictCreate2(bytes32(0), type(WithdrawImplementation).creationCode);
        address predictedAdmin = _predictCreate2(
            bytes32(0),
            abi.encodePacked(type(AdminWithdrawManager).creationCode, abi.encode(deployer, deployer, signer))
        );

        _logPredicted("CounterfactualDeposit", predictedDeposit);
        _logPredicted("CounterfactualDepositFactory", predictedFactory);
        _logPredicted("WithdrawImplementation", predictedWithdraw);
        _logPredicted("AdminWithdrawManager", predictedAdmin);

        address predictedSpokePool;
        if (deploySpokePool) {
            predictedSpokePool = _predictCreate2(
                bytes32(0),
                abi.encodePacked(type(CounterfactualDepositSpokePool).creationCode, abi.encode(registry))
            );
            _logPredicted("CounterfactualDepositSpokePool", predictedSpokePool);
        }

        address predictedCctp;
        if (deployCctp) {
            predictedCctp = _predictCreate2(
                bytes32(0),
                abi.encodePacked(type(CounterfactualDepositCCTP).creationCode, abi.encode(registry))
            );
            _logPredicted("CounterfactualDepositCCTP", predictedCctp);
        }

        address predictedOft;
        if (deployOft) {
            predictedOft = _predictCreate2(
                bytes32(0),
                abi.encodePacked(type(CounterfactualDepositOFT).creationCode, abi.encode(registry))
            );
            _logPredicted("CounterfactualDepositOFT", predictedOft);
        }

        console.log("============================================");

        string memory broadcastFlag = broadcast ? " --broadcast --verify --retries 5 --delay 10" : "";

        // --- CounterfactualDeposit (base implementation that all clones proxy to) ---
        if (predictedDeposit.code.length > 0) {
            console.log("CounterfactualDeposit: ALREADY DEPLOYED");
        } else {
            console.log("Deploying CounterfactualDeposit...");
            _runForgeScript(
                rpcUrl,
                broadcastFlag,
                string.concat(SCRIPT_DIR, "DeployCounterfactualDeposit.s.sol"),
                "DeployCounterfactualDeposit",
                "",
                profile
            );
        }

        // --- CounterfactualDepositFactory (factory that deploys deterministic clones via CREATE2) ---
        if (predictedFactory.code.length > 0) {
            console.log("CounterfactualDepositFactory: ALREADY DEPLOYED");
        } else {
            console.log("Deploying CounterfactualDepositFactory...");
            _runForgeScript(
                rpcUrl,
                broadcastFlag,
                string.concat(SCRIPT_DIR, "DeployCounterfactualDepositFactory.s.sol"),
                "DeployCounterfactualDepositFactory",
                "",
                profile
            );
        }

        // --- WithdrawImplementation (withdraw logic, included as a merkle leaf in each clone) ---
        if (predictedWithdraw.code.length > 0) {
            console.log("WithdrawImplementation: ALREADY DEPLOYED");
        } else {
            console.log("Deploying WithdrawImplementation...");
            _runForgeScript(
                rpcUrl,
                broadcastFlag,
                string.concat(SCRIPT_DIR, "DeployWithdrawImplementation.s.sol"),
                "DeployWithdrawImplementation",
                "",
                profile
            );
        }

        // --- CounterfactualDepositSpokePool (deposit implementation for Across SpokePool) ---
        if (deploySpokePool) {
            if (predictedSpokePool.code.length > 0) {
                console.log("CounterfactualDepositSpokePool: ALREADY DEPLOYED");
            } else {
                console.log("Deploying CounterfactualDepositSpokePool...");
                _runForgeScript(
                    rpcUrl,
                    broadcastFlag,
                    string.concat(SCRIPT_DIR, "DeployCounterfactualDepositSpokePool.s.sol"),
                    "DeployCounterfactualDepositSpokePool",
                    string.concat(' --sig "run(address)" ', vm.toString(registry)),
                    profile
                );
            }
        }

        // --- CounterfactualDepositCCTP (deposit implementation for Circle CCTP) ---
        if (deployCctp) {
            if (predictedCctp.code.length > 0) {
                console.log("CounterfactualDepositCCTP: ALREADY DEPLOYED");
            } else {
                console.log("Deploying CounterfactualDepositCCTP...");
                _runForgeScript(
                    rpcUrl,
                    broadcastFlag,
                    string.concat(SCRIPT_DIR, "DeployCounterfactualDepositCCTP.s.sol"),
                    "DeployCounterfactualDepositCCTP",
                    string.concat(' --sig "run(address)" ', vm.toString(registry)),
                    profile
                );
            }
        }

        // --- CounterfactualDepositOFT (deposit implementation for LayerZero OFT) ---
        if (deployOft) {
            if (predictedOft.code.length > 0) {
                console.log("CounterfactualDepositOFT: ALREADY DEPLOYED");
            } else {
                console.log("Deploying CounterfactualDepositOFT...");
                _runForgeScript(
                    rpcUrl,
                    broadcastFlag,
                    string.concat(SCRIPT_DIR, "DeployCounterfactualDepositOFT.s.sol"),
                    "DeployCounterfactualDepositOFT",
                    string.concat(' --sig "run(address)" ', vm.toString(registry)),
                    profile
                );
            }
        }

        // --- AdminWithdrawManager (admin contract for managing withdrawals from clones) ---
        if (predictedAdmin.code.length > 0) {
            console.log("AdminWithdrawManager: ALREADY DEPLOYED");
        } else {
            console.log("Deploying AdminWithdrawManager...");
            _runForgeScript(
                rpcUrl,
                broadcastFlag,
                string.concat(SCRIPT_DIR, "DeployAdminWithdrawManager.s.sol"),
                "DeployAdminWithdrawManager",
                "",
                profile
            );
        }

        // --- Transfer AdminWithdrawManager roles ---
        if (transferRoles) {
            address ownerAndDirectWithdrawer = config.get("ownerAndDirectWithdrawer").toAddress();
            require(ownerAndDirectWithdrawer != address(0), "config: ownerAndDirectWithdrawer is zero or missing");
            AdminWithdrawManager manager = AdminWithdrawManager(predictedAdmin);

            console.log("--------------------------------------------");
            console.log("Transferring AdminWithdrawManager roles to:", ownerAndDirectWithdrawer);

            vm.startBroadcast(deployerPrivateKey);

            // Transfer directWithdrawer first, then verify before transferring ownership.
            if (ownerAndDirectWithdrawer != manager.directWithdrawer()) {
                manager.setDirectWithdrawer(ownerAndDirectWithdrawer);

                if (manager.directWithdrawer() != ownerAndDirectWithdrawer) {
                    console.log("ERROR: directWithdrawer transfer failed. Skipping ownership transfer.");
                    vm.stopBroadcast();
                } else {
                    if (ownerAndDirectWithdrawer != manager.owner()) {
                        manager.transferOwnership(ownerAndDirectWithdrawer);
                    }
                    vm.stopBroadcast();
                }
            } else {
                // directWithdrawer already correct, just transfer ownership if needed.
                if (ownerAndDirectWithdrawer != manager.owner()) {
                    manager.transferOwnership(ownerAndDirectWithdrawer);
                }
                vm.stopBroadcast();
            }
        }

        console.log("============================================");
        console.log("All deployments complete!");
        console.log("============================================");
    }

    function _logPredicted(string memory name, address predicted) internal view {
        string memory status = predicted.code.length > 0 ? " [ALREADY DEPLOYED]" : "";
        console.log("  %s%s: %s", name, status, predicted);
    }

    /// @dev Invokes a single deploy script via `forge script` using vm.ffi().
    function _runForgeScript(
        string memory rpcUrl,
        string memory broadcastFlag,
        string memory scriptPath,
        string memory contractName,
        string memory sigArgs,
        string memory profile
    ) internal {
        // Append `|| true` so that non-fatal failures (e.g. etherscan verification
        // timing out) don't cause ffi to revert and halt subsequent deployments.
        string memory cmd = string.concat(
            "FOUNDRY_PROFILE=",
            profile,
            " forge script ",
            scriptPath,
            ":",
            contractName,
            sigArgs,
            " --rpc-url ",
            rpcUrl,
            broadcastFlag,
            " -vvvv || true"
        );

        console.log("  cmd: %s", cmd);

        string[] memory args = new string[](3);
        args[0] = "bash";
        args[1] = "-c";
        args[2] = cmd;
        vm.ffi(args);

        console.log("Done.");
    }
}
