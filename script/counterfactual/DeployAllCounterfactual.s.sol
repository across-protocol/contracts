// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Script } from "forge-std/Script.sol";
import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";
import { CounterfactualConfig } from "./CounterfactualConfig.sol";
import { WithdrawImplementation } from "../../contracts/periphery/counterfactual/WithdrawImplementation.sol";
import { CounterfactualDepositSpokePool } from "../../contracts/periphery/counterfactual/CounterfactualDepositSpokePool.sol";
import { CounterfactualDepositCCTP } from "../../contracts/periphery/counterfactual/CounterfactualDepositCCTP.sol";
import { CounterfactualDepositOFT } from "../../contracts/periphery/counterfactual/CounterfactualDepositOFT.sol";
import { CounterfactualDepositVanillaCCTP } from "../../contracts/periphery/counterfactual/CounterfactualDepositVanillaCCTP.sol";
import { AdminWithdrawManager } from "../../contracts/periphery/counterfactual/AdminWithdrawManager.sol";

// Deploys counterfactual contracts via CREATE2 using the deterministic deployment proxy
// (0x4e59b44847b379578588920cA78FbF26c0B4956C). Each individual deploy script is invoked via ffi
// so broadcast artifacts are recorded in each script's own folder.
//
// CREATE2 addresses are determined by (factory, salt, initCode). Contracts with identical initCode
// across chains get the same address everywhere; contracts with chain-specific constructor args get
// chain-specific addresses.
//
// Same address across all chains (the cross-chain anchors):
//   - CounterfactualBeacon implementation (no constructor args)
//   - CounterfactualBeacon PROXY (ERC1967Proxy initialized with the chain-invariant deployer as owner —
//     every counterfactual proxy and the factory embed it, so this MUST be identical across chains; see the
//     determinism notes in CounterfactualConfig)
//   - CounterfactualDeposit / dispatcher (constructor takes the chain-invariant beacon proxy)
//   - CounterfactualDepositFactory (constructor takes the chain-invariant beacon proxy)
//   - WithdrawImplementation (no constructor args)
//   - AdminWithdrawManager (same constructor args on all chains)
//
// Chain-specific addresses (different constructor args per chain):
//   - CounterfactualDepositSpokePool   (spokePool, signer, wrappedNativeToken)
//   - CounterfactualDepositCCTP        (srcPeriphery, sourceDomain, signer)
//   - CounterfactualDepositOFT         (oftPeriphery, srcEid, signer)
//   - CounterfactualDepositVanillaCCTP (cctpV2TokenMessenger, signer)
//
// IMPORTANT: the same deployer (MNEMONIC index 0) must be used on every chain — it is the beacon proxy's
// initial owner and therefore part of the beacon proxy address (and thus every counterfactual address).
//
// Advantages over nonce-based (CREATE) deployment:
//   - No fresh EOA required — any funded address can deploy
//   - No nonce burning for skipped contracts
//   - Idempotent — already-deployed contracts are auto-skipped
//
// Configuration:
//   - Operational params (signer, ownerAndDirectWithdrawer): script/counterfactual/config.toml
//   - Chain-specific params (spokePool, wrappedNativeToken, cctp/oft periphery + domain/eid,
//     cctpV2TokenMessenger): auto-resolved from constants.json and deployed-addresses.json
//   - AdminWithdrawManager is deployed with deployer as owner/directWithdrawer and signer from
//     config.toml. Role transfers are done by this script after all ffi deployments complete, with a
//     safety check that directWithdrawer transferred before ownership. The beacon stack hands ownership to
//     the multisig when `transferRoles` is set (Ownable2Step — the multisig accepts out of band).
//
// Always deployed (in order — the dispatcher precedes the beacon so the beacon can wire it):
//   - CounterfactualDeposit (dispatcher) via DeployCounterfactualDeposit
//   - CounterfactualBeacon (impl + proxy) + setImplementation(dispatcher) via DeployCounterfactualBeacon
//   - CounterfactualDepositFactory, WithdrawImplementation, AdminWithdrawManager
//
// Optionally deployed (controlled by bool arguments):
//   - CounterfactualDepositSpokePool   (deploySpokePool)
//   - CounterfactualDepositCCTP        (deployCctp)
//   - CounterfactualDepositOFT         (deployOft)
//   - CounterfactualDepositVanillaCCTP (deployVanillaCctp)
//
// Environment variables:
//   MNEMONIC          - Required. Mnemonic phrase for key derivation.
//
// How to run:
// 1. Edit script/counterfactual/config.toml with signer and ownerAndDirectWithdrawer per chain
// 2. `source .env` where `.env` has MNEMONIC="x x x ... x" and ETHERSCAN_API_KEY="x"
// 3. forge script \
//      script/counterfactual/DeployAllCounterfactual.s.sol:DeployAllCounterfactual \
//      --sig "run(string,bool,bool,bool,bool,bool,bool,string)" <rpcUrl> true true true true true true counterfactual \
//      --rpc-url <rpcUrl> --ffi -vvvv
// 4. Verify the logged predicted addresses and forge commands look correct
contract DeployAllCounterfactual is Script, Test, CounterfactualConfig {
    string constant SCRIPT_DIR = "script/counterfactual/";

    // Grouped to keep the deploy flow under the stack-slot limit.
    struct Predicted {
        address beaconProxy;
        address dispatcher;
        address factory;
        address withdraw;
        address admin;
        address spokePool;
        address cctp;
        address oft;
        address vanillaCctp;
    }

    /// @param rpcUrl RPC URL for the target chain.
    /// @param deploySpokePool If true, deploy CounterfactualDepositSpokePool.
    /// @param deployCctp If true, deploy CounterfactualDepositCCTP (sponsored).
    /// @param deployOft If true, deploy CounterfactualDepositOFT.
    /// @param deployVanillaCctp If true, deploy CounterfactualDepositVanillaCCTP (non-sponsored CCTP v2).
    /// @param transferRoles If true, transfer AdminWithdrawManager + beacon ownership to config.toml addresses.
    /// @param broadcast If true, broadcast transactions on-chain.
    /// @param profile Foundry profile to use for sub-script invocations (e.g. "counterfactual").
    function run(
        string calldata rpcUrl,
        bool deploySpokePool,
        bool deployCctp,
        bool deployOft,
        bool deployVanillaCctp,
        bool transferRoles,
        bool broadcast,
        string calldata profile
    ) external {
        address signer = _loadSigner();
        bytes32 salt = _loadSalt();
        uint256 deployerPrivateKey = vm.deriveKey(vm.envString("MNEMONIC"), 0);
        address deployer = vm.addr(deployerPrivateKey);

        // Resolve chain-specific params.
        address spokePool;
        address wrappedNativeToken;
        if (deploySpokePool) {
            spokePool = _resolveSpokePool();
            wrappedNativeToken = _resolveWrappedNativeToken();
        }
        address cctpPeriphery;
        uint32 cctpDomain;
        if (deployCctp) {
            require(hasCctpDomain(block.chainid), "CCTP not supported on this chain");
            cctpPeriphery = _resolveCctpPeriphery();
            require(cctpPeriphery != address(0), "CCTP periphery not deployed on this chain");
            cctpDomain = getCircleDomainId(block.chainid);
        }
        address oftPeriphery;
        uint32 oftEid;
        if (deployOft) {
            require(hasOftEid(block.chainid), "OFT not supported on this chain");
            oftPeriphery = _resolveOftPeriphery();
            require(oftPeriphery != address(0), "OFT periphery not deployed on this chain");
            oftEid = uint32(getOftEid(block.chainid));
        }
        address vanillaTokenMessenger;
        if (deployVanillaCctp) {
            vanillaTokenMessenger = _resolveCctpV2TokenMessenger();
            require(vanillaTokenMessenger != address(0), "CCTP v2 TokenMessenger not available on this chain");
        }

        // Predict addresses (beacon proxy + dispatcher + factory derive from the chain-invariant deployer).
        Predicted memory p;
        p.beaconProxy = _predictBeaconProxy(deployer, salt);
        p.dispatcher = _predictCreate2(salt, _dispatcherInitCode(p.beaconProxy));
        p.factory = _predictCreate2(salt, _factoryInitCode(p.beaconProxy));
        p.withdraw = _predictCreate2(salt, type(WithdrawImplementation).creationCode);
        p.admin = _predictCreate2(
            salt,
            abi.encodePacked(type(AdminWithdrawManager).creationCode, abi.encode(deployer, deployer, signer))
        );
        if (deploySpokePool)
            p.spokePool = _predictCreate2(
                salt,
                abi.encodePacked(
                    type(CounterfactualDepositSpokePool).creationCode,
                    abi.encode(spokePool, signer, wrappedNativeToken)
                )
            );
        if (deployCctp)
            p.cctp = _predictCreate2(
                salt,
                abi.encodePacked(
                    type(CounterfactualDepositCCTP).creationCode,
                    abi.encode(cctpPeriphery, cctpDomain, signer)
                )
            );
        if (deployOft)
            p.oft = _predictCreate2(
                salt,
                abi.encodePacked(type(CounterfactualDepositOFT).creationCode, abi.encode(oftPeriphery, oftEid, signer))
            );
        if (deployVanillaCctp)
            p.vanillaCctp = _predictCreate2(
                salt,
                abi.encodePacked(
                    type(CounterfactualDepositVanillaCCTP).creationCode,
                    abi.encode(vanillaTokenMessenger, signer)
                )
            );

        console.log("============================================");
        console.log("Counterfactual Contracts CREATE2 Deployment");
        console.log("============================================");
        console.log("Deployer:  ", deployer);
        console.log("Chain ID:  ", block.chainid);
        console.log("Broadcast: ", broadcast);
        console.log("Signer:    ", signer);
        console.log("Transfer roles:", transferRoles);
        console.log("--------------------------------------------");
        console.log("Predicted addresses:");
        _logPredicted("CounterfactualBeacon proxy", p.beaconProxy);
        _logPredicted("CounterfactualDeposit (dispatcher)", p.dispatcher);
        _logPredicted("CounterfactualDepositFactory", p.factory);
        _logPredicted("WithdrawImplementation", p.withdraw);
        _logPredicted("AdminWithdrawManager", p.admin);
        if (deploySpokePool) _logPredicted("CounterfactualDepositSpokePool", p.spokePool);
        if (deployCctp) _logPredicted("CounterfactualDepositCCTP", p.cctp);
        if (deployOft) _logPredicted("CounterfactualDepositOFT", p.oft);
        if (deployVanillaCctp) _logPredicted("CounterfactualDepositVanillaCCTP", p.vanillaCctp);
        console.log("============================================");

        string memory broadcastFlag = broadcast ? " --broadcast --verify --retries 5 --delay 10" : "";

        // --- CounterfactualDeposit (dispatcher) — deployed first so the beacon can wire it (and so it gets
        //     its own broadcast artifact). Bound to the deterministic beacon proxy, which needn't exist yet. ---
        _deployIfNeeded(
            p.dispatcher,
            "CounterfactualDeposit",
            rpcUrl,
            broadcastFlag,
            "DeployCounterfactualDeposit",
            "",
            profile
        );

        // --- Beacon (impl + proxy) + setImplementation(dispatcher) — wires the dispatcher deployed above. ---
        if (p.beaconProxy.code.length > 0) {
            console.log("CounterfactualBeacon: ALREADY DEPLOYED");
        } else {
            console.log("Deploying + wiring beacon...");
            _runForgeScript(
                rpcUrl,
                broadcastFlag,
                string.concat(SCRIPT_DIR, "DeployCounterfactualBeacon.s.sol"),
                "DeployCounterfactualBeacon",
                string.concat(' --sig "run(bool)" ', vm.toString(transferRoles)),
                profile
            );
        }

        // --- CounterfactualDepositFactory (mints deterministic clones; embeds the beacon proxy) ---
        _deployIfNeeded(
            p.factory,
            "CounterfactualDepositFactory",
            rpcUrl,
            broadcastFlag,
            "DeployCounterfactualDepositFactory",
            "",
            profile
        );

        // --- WithdrawImplementation (withdraw logic, included as a merkle leaf in each clone) ---
        _deployIfNeeded(
            p.withdraw,
            "WithdrawImplementation",
            rpcUrl,
            broadcastFlag,
            "DeployWithdrawImplementation",
            "",
            profile
        );

        // --- CounterfactualDepositSpokePool ---
        if (deploySpokePool) {
            _deployIfNeeded(
                p.spokePool,
                "CounterfactualDepositSpokePool",
                rpcUrl,
                broadcastFlag,
                "DeployCounterfactualDepositSpokePool",
                string.concat(
                    ' --sig "run(address,address,address)" ',
                    vm.toString(spokePool),
                    " ",
                    vm.toString(signer),
                    " ",
                    vm.toString(wrappedNativeToken)
                ),
                profile
            );
        }

        // --- CounterfactualDepositCCTP ---
        if (deployCctp) {
            _deployIfNeeded(
                p.cctp,
                "CounterfactualDepositCCTP",
                rpcUrl,
                broadcastFlag,
                "DeployCounterfactualDepositCCTP",
                string.concat(
                    ' --sig "run(address,uint32,address)" ',
                    vm.toString(cctpPeriphery),
                    " ",
                    vm.toString(uint256(cctpDomain)),
                    " ",
                    vm.toString(signer)
                ),
                profile
            );
        }

        // --- CounterfactualDepositOFT ---
        if (deployOft) {
            _deployIfNeeded(
                p.oft,
                "CounterfactualDepositOFT",
                rpcUrl,
                broadcastFlag,
                "DeployCounterfactualDepositOFT",
                string.concat(
                    ' --sig "run(address,uint32,address)" ',
                    vm.toString(oftPeriphery),
                    " ",
                    vm.toString(uint256(oftEid)),
                    " ",
                    vm.toString(signer)
                ),
                profile
            );
        }

        // --- CounterfactualDepositVanillaCCTP ---
        if (deployVanillaCctp) {
            _deployIfNeeded(
                p.vanillaCctp,
                "CounterfactualDepositVanillaCCTP",
                rpcUrl,
                broadcastFlag,
                "DeployCounterfactualDepositVanillaCCTP",
                string.concat(
                    ' --sig "run(address,address)" ',
                    vm.toString(vanillaTokenMessenger),
                    " ",
                    vm.toString(signer)
                ),
                profile
            );
        }

        // --- AdminWithdrawManager ---
        _deployIfNeeded(
            p.admin,
            "AdminWithdrawManager",
            rpcUrl,
            broadcastFlag,
            "DeployAdminWithdrawManager",
            "",
            profile
        );

        // --- Transfer AdminWithdrawManager roles ---
        if (transferRoles) {
            address ownerAndDirectWithdrawer = config.get("ownerAndDirectWithdrawer").toAddress();
            require(ownerAndDirectWithdrawer != address(0), "config: ownerAndDirectWithdrawer is zero or missing");
            AdminWithdrawManager manager = AdminWithdrawManager(p.admin);

            console.log("--------------------------------------------");
            console.log("Transferring AdminWithdrawManager roles to:", ownerAndDirectWithdrawer);

            vm.startBroadcast(deployerPrivateKey);
            // Transfer directWithdrawer first, then verify before transferring ownership.
            if (ownerAndDirectWithdrawer != manager.directWithdrawer()) {
                manager.setDirectWithdrawer(ownerAndDirectWithdrawer);
            }
            if (manager.directWithdrawer() != ownerAndDirectWithdrawer) {
                console.log("ERROR: directWithdrawer transfer failed. Skipping ownership transfer.");
            } else if (ownerAndDirectWithdrawer != manager.owner()) {
                manager.transferOwnership(ownerAndDirectWithdrawer);
            }
            vm.stopBroadcast();
        }

        console.log("============================================");
        console.log("All deployments complete!");
        console.log("============================================");
    }

    function _logPredicted(string memory name, address predicted) internal view {
        string memory status = predicted.code.length > 0 ? " [ALREADY DEPLOYED]" : "";
        console.log("  %s%s: %s", name, status, predicted);
    }

    /// @dev Invoke a sub-deploy script via ffi unless the predicted address already has code.
    function _deployIfNeeded(
        address predicted,
        string memory name,
        string memory rpcUrl,
        string memory broadcastFlag,
        string memory contractName,
        string memory sigArgs,
        string memory profile
    ) internal {
        if (predicted.code.length > 0) {
            console.log(string.concat(name, ": ALREADY DEPLOYED"));
            return;
        }
        console.log(string.concat("Deploying ", name, "..."));
        _runForgeScript(
            rpcUrl,
            broadcastFlag,
            string.concat(SCRIPT_DIR, contractName, ".s.sol"),
            contractName,
            sigArgs,
            profile
        );
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
        // Append `|| true` so non-fatal failures (e.g. etherscan verification timing out) don't cause ffi
        // to revert and halt subsequent deployments.
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
