// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Script } from "forge-std/Script.sol";
import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { CounterfactualConfig } from "./CounterfactualConfig.sol";
import {
    CounterfactualBeacon,
    CounterfactualChainConfig
} from "../../contracts/periphery/counterfactual/CounterfactualBeacon.sol";
import { CounterfactualBeaconBase } from "../../contracts/periphery/counterfactual/CounterfactualBeaconBase.sol";
import { CounterfactualBeaconBootstrap } from "../../contracts/periphery/counterfactual/CounterfactualBeaconBootstrap.sol";
import { ICounterfactualBeacon } from "../../contracts/interfaces/ICounterfactualBeacon.sol";
import { CounterfactualDeposit } from "../../contracts/periphery/counterfactual/CounterfactualDeposit.sol";
import { CounterfactualDepositFactory } from "../../contracts/periphery/counterfactual/CounterfactualDepositFactory.sol";
import { WithdrawImplementation } from "../../contracts/periphery/counterfactual/WithdrawImplementation.sol";
import { CounterfactualDepositSpokePool } from "../../contracts/periphery/counterfactual/CounterfactualDepositSpokePool.sol";
import { CounterfactualDepositSpokePoolTr } from "../../contracts/periphery/counterfactual/CounterfactualDepositSpokePoolTr.sol";
import { CounterfactualDepositCCTP } from "../../contracts/periphery/counterfactual/CounterfactualDepositCCTP.sol";
import { CounterfactualDepositOFT } from "../../contracts/periphery/counterfactual/CounterfactualDepositOFT.sol";
import { CounterfactualDepositVanillaCCTP } from "../../contracts/periphery/counterfactual/CounterfactualDepositVanillaCCTP.sol";
import { AdminWithdrawManager } from "../../contracts/periphery/counterfactual/AdminWithdrawManager.sol";

// Deploys counterfactual contracts via CREATE2 using the deterministic deployment proxy
// (0x4e59b44847b379578588920cA78FbF26c0B4956C). Each deploy script is invoked via ffi so broadcast artifacts
// land in each script's own folder.
//
// CREATE2 addresses depend on (factory, salt, initCode). All chain-specific values (bridge endpoints, fee
// signer, token addresses) live on the per-chain CounterfactualBeacon impl, so the dispatcher and every leaf
// impl are byte-identical across chains and land at the SAME CREATE2 address everywhere.
//
// SAME address across all chains:
//   - CounterfactualBeacon PROXY (ERC1967Proxy over the chain-identical bootstrap, owned by the
//     chain-invariant deployer => identical init code => identical address; the anchor every counterfactual
//     proxy and the factory embed)
//   - CounterfactualBeaconBootstrap (no constructor args)
//   - CounterfactualDeposit / dispatcher (constructor takes the chain-invariant beacon proxy)
//   - CounterfactualDepositFactory (no constructor args)
//   - WithdrawImplementation (no constructor args)
//   - CounterfactualDepositCCTP / OFT / VanillaCCTP (no constructor args)
//   - CounterfactualDepositSpokePool (no constructor args; input-token-agnostic via leaf getter selector)
//   - AdminWithdrawManager (same constructor args on all chains)
//
// CHAIN-SPECIFIC address (intentionally):
//   - CounterfactualBeacon IMPLEMENTATION (bakes the chain's ChainConfig as immutables). It sits behind the
//     address-stable proxy, so the proxy everything embeds stays identical everywhere.
//
// Advantages over nonce-based (CREATE) deployment:
//   - No fresh EOA required — any funded address can deploy
//   - No nonce burning for skipped contracts
//   - No ordering dependency — deploy in any order (except the beacon stack, which is one atomic script)
//   - Idempotent — already-deployed contracts are auto-skipped
//
// Configuration:
//   - Operational params (signer, ownerAndDirectWithdrawer): script/counterfactual/config.toml
//   - Chain-specific params (spokePool, wrappedNativeToken, nativeToken, cctp/oft periphery + domain/eid,
//     USDC/USDT, cctpTokenMessenger): auto-resolved from constants.json + deployed-addresses.json and baked
//     into the beacon impl by DeployCounterfactualBeacon. `nativeToken` defaults to the native sentinel;
//     override at `.NATIVE_TOKEN.<chainId>` for chains whose gas-token route is an ERC-20.
//   - AdminWithdrawManager is deployed with deployer as owner/directWithdrawer and signer from config.toml.
//     This script transfers those roles after all ffi deployments, verifying directWithdrawer transferred
//     before ownership.
//
// Always deployed:
//   - Beacon stack (bootstrap + proxy + chain-specific impl + dispatcher) via DeployCounterfactualBeacon
//   - CounterfactualDepositFactory, WithdrawImplementation, CounterfactualDepositVanillaCCTP,
//     AdminWithdrawManager
//
// Optionally deployed (bool args): CounterfactualDepositSpokePool (deploySpokePool),
// CounterfactualDepositCCTP (deployCctp), CounterfactualDepositOFT (deployOft).
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

        // CCTP / OFT gating: leaf impls are chain-identical, but only deploy where the route is configured
        // (matching the per-script guards). Also require the upstream periphery so the beacon doesn't bake
        // `address(0)`, which would silently brick every leaf with `RouteNotConfigured`.
        if (deployCctp) {
            require(hasCctpDomain(block.chainid), "CCTP not supported on this chain");
            require(_resolveCctpPeriphery() != address(0), "CCTP periphery not deployed on this chain");
        }
        if (deployOft) {
            require(hasOftEid(block.chainid), "OFT not supported on this chain");
            require(_resolveOftPeriphery() != address(0), "OFT periphery not deployed on this chain");
        }

        uint256 deployerPrivateKey = vm.deriveKey(vm.envString("MNEMONIC"), 0);
        address deployer = vm.addr(deployerPrivateKey);

        // Predict the chain-invariant beacon proxy + dispatcher addresses (like DeployCounterfactualBeacon)
        // for logging and idempotency checks.
        address predictedProxy = _predictBeaconProxy(deployer);
        address predictedDispatcher = _predictCreate2(
            bytes32(0),
            abi.encodePacked(
                type(CounterfactualDeposit).creationCode,
                abi.encode(ICounterfactualBeacon(predictedProxy))
            )
        );

        // Log predicted addresses upfront so they can be verified before deploying.
        console.log("============================================");
        console.log("Counterfactual Contracts CREATE2 Deployment");
        console.log("============================================");
        console.log("Deployer:  ", deployer);
        console.log("Chain ID:  ", block.chainid);
        console.log("Broadcast: ", broadcast);
        console.log("--------------------------------------------");
        console.log("Resolved parameters:");
        console.log("  Signer:             ", signer);
        console.log("  Deploy SpokePool:   ", deploySpokePool);
        console.log("  Deploy CCTP:        ", deployCctp);
        console.log("  Deploy OFT:         ", deployOft);
        console.log("  Transfer roles:     ", transferRoles);
        console.log("--------------------------------------------");
        console.log("Predicted addresses:");

        // Beacon stack + always-on contracts.
        address predictedFactory = _predictCreate2(bytes32(0), type(CounterfactualDepositFactory).creationCode);
        address predictedWithdraw = _predictCreate2(bytes32(0), type(WithdrawImplementation).creationCode);
        address predictedVanilla = _predictCreate2(bytes32(0), type(CounterfactualDepositVanillaCCTP).creationCode);
        address predictedAdmin = _predictCreate2(
            bytes32(0),
            abi.encodePacked(type(AdminWithdrawManager).creationCode, abi.encode(deployer, deployer, signer))
        );

        _logPredicted("CounterfactualBeacon (proxy)", predictedProxy);
        _logPredicted("CounterfactualDeposit (dispatcher)", predictedDispatcher);
        _logPredicted("CounterfactualDepositFactory", predictedFactory);
        _logPredicted("WithdrawImplementation", predictedWithdraw);
        _logPredicted("CounterfactualDepositVanillaCCTP", predictedVanilla);
        _logPredicted("AdminWithdrawManager", predictedAdmin);

        address predictedSpokePool;
        if (deploySpokePool) {
            // On Tron the sub-script deploys `CounterfactualDepositSpokePoolTr` (different bytecode ⇒
            // different CREATE2 address) for Tron USDT's non-standard `transfer`.
            bool isTron = block.chainid == 728126428;
            bytes memory spokePoolCode = isTron
                ? type(CounterfactualDepositSpokePoolTr).creationCode
                : type(CounterfactualDepositSpokePool).creationCode;
            predictedSpokePool = _predictCreate2(bytes32(0), spokePoolCode);
            _logPredicted(
                isTron ? "CounterfactualDepositSpokePoolTr" : "CounterfactualDepositSpokePool",
                predictedSpokePool
            );
        }

        address predictedCctp;
        if (deployCctp) {
            predictedCctp = _predictCreate2(bytes32(0), type(CounterfactualDepositCCTP).creationCode);
            _logPredicted("CounterfactualDepositCCTP", predictedCctp);
        }

        address predictedOft;
        if (deployOft) {
            predictedOft = _predictCreate2(bytes32(0), type(CounterfactualDepositOFT).creationCode);
            _logPredicted("CounterfactualDepositOFT", predictedOft);
        }

        console.log("============================================");

        string memory broadcastFlag = broadcast ? " --broadcast --verify --retries 5 --delay 10" : "";

        // --- Beacon stack (bootstrap + proxy + chain-specific impl + upgrade + dispatcher + setImplementation) ---
        // The one ordering-dependent step: must run before the dispatcher is usable. The dispatcher is
        // deployed here by DeployCounterfactualBeacon (not standalone) so it binds to the fresh beacon proxy.
        //
        // Code at both addresses is necessary but not sufficient: a prior broadcast may have stopped between
        // deploying the proxy/dispatcher and `setImplementation(dispatcher)`, leaving the proxy on the
        // bootstrap (no `implementation()` selector ⇒ staticcall reverts) or stale. Skip only when the proxy
        // actually resolves the dispatcher.
        if (
            predictedDispatcher.code.length > 0 &&
            predictedProxy.code.length > 0 &&
            _beaconWiredTo(predictedProxy, predictedDispatcher)
        ) {
            console.log("Beacon stack (proxy + dispatcher): ALREADY DEPLOYED");
            // The proxy resolves the dispatcher, but chain config lives in the beacon impl's immutables. If
            // constants.json/deployed-addresses.json changed since the beacon was deployed (e.g. a missing
            // usdt/cctpTokenMessenger/periphery filled in), those immutables are stale — only fixable via a
            // registry UUPS upgrade. Surface the mismatch loudly so a silently-bricked route isn't missed.
            _warnIfBeaconConfigStale(predictedProxy);
        } else {
            console.log("Deploying Beacon stack (bootstrap + proxy + impl + dispatcher)...");
            _runForgeScript(
                rpcUrl,
                broadcastFlag,
                string.concat(SCRIPT_DIR, "DeployCounterfactualBeacon.s.sol"),
                "DeployCounterfactualBeacon",
                "",
                profile
            );
        }

        // --- CounterfactualDepositFactory (deploys deterministic clones via CREATE2) ---
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

        // --- CounterfactualDepositSpokePool (input-token-agnostic) ---
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
                    "",
                    profile
                );
            }
        }

        // --- CounterfactualDepositCCTP (sponsored Circle CCTP) ---
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
                    "",
                    profile
                );
            }
        }

        // --- CounterfactualDepositOFT (LayerZero OFT) ---
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
                    "",
                    profile
                );
            }
        }

        // --- CounterfactualDepositVanillaCCTP (vanilla, non-sponsored Circle CCTP v2) ---
        if (predictedVanilla.code.length > 0) {
            console.log("CounterfactualDepositVanillaCCTP: ALREADY DEPLOYED");
        } else {
            console.log("Deploying CounterfactualDepositVanillaCCTP...");
            _runForgeScript(
                rpcUrl,
                broadcastFlag,
                string.concat(SCRIPT_DIR, "DeployCounterfactualDepositVanillaCCTP.s.sol"),
                "DeployCounterfactualDepositVanillaCCTP",
                "",
                profile
            );
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

        // --- Transfer beacon + AdminWithdrawManager roles ---
        if (transferRoles) {
            address ownerAndDirectWithdrawer = config.get("ownerAndDirectWithdrawer").toAddress();
            require(ownerAndDirectWithdrawer != address(0), "config: ownerAndDirectWithdrawer is zero or missing");

            console.log("--------------------------------------------");

            // The beacon admin can retarget every counterfactual proxy and UUPS-upgrade the registry, so it
            // must end up on the per-chain multisig, not the deployer EOA (Ownable2Step: new owner accepts
            // out of band). Own broadcast scope, separate from the AdminWithdrawManager block below.
            CounterfactualBeacon beacon = CounterfactualBeacon(predictedProxy);
            if (beacon.owner() != ownerAndDirectWithdrawer && beacon.pendingOwner() != ownerAndDirectWithdrawer) {
                console.log("Transferring beacon ownership to:", ownerAndDirectWithdrawer);
                vm.startBroadcast(deployerPrivateKey);
                beacon.transferOwnership(ownerAndDirectWithdrawer);
                vm.stopBroadcast();
            } else {
                console.log("Beacon ownership: already transferred or pending acceptance");
            }

            AdminWithdrawManager manager = AdminWithdrawManager(predictedAdmin);
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

    /// @notice Predicts the chain-invariant beacon proxy address for the given deployer (bootstrap owner).
    /// @dev Mirrors DeployCounterfactualBeacon: ERC1967Proxy over the chain-identical bootstrap with the
    ///      deployer as owner (chain-invariant => identical init code => identical address).
    function _predictBeaconProxy(address deployer) internal pure returns (address) {
        address bootstrap = _predictCreate2(bytes32(0), type(CounterfactualBeaconBootstrap).creationCode);
        bytes memory proxyInitCode = abi.encodePacked(
            type(ERC1967Proxy).creationCode,
            abi.encode(bootstrap, abi.encodeCall(CounterfactualBeaconBootstrap.initialize, (deployer)))
        );
        return _predictCreate2(bytes32(0), proxyInitCode);
    }

    /// @dev True when the beacon proxy's `implementation()` already resolves to the expected dispatcher.
    ///      False when the staticcall reverts/returns malformed data (proxy still on the bootstrap, no
    ///      `implementation()` selector) — meaning `setImplementation` hasn't run and the beacon sub-script must.
    function _beaconWiredTo(address proxy, address expectedImpl) internal view returns (bool) {
        (bool ok, bytes memory ret) = proxy.staticcall(abi.encodeCall(CounterfactualBeaconBase.implementation, ()));
        if (!ok || ret.length != 32) return false;
        return abi.decode(ret, (address)) == expectedImpl;
    }

    /// @dev Compares the chain config baked into the live beacon impl against the current resolvers
    ///      (constants.json + deployed-addresses.json + config.toml). Each mismatch is logged individually,
    ///      with a summary pointing to the UUPS-upgrade remediation. Read-only — no broadcasts.
    function _warnIfBeaconConfigStale(address proxy) internal {
        CounterfactualChainConfig memory expected = _buildChainConfig();
        CounterfactualBeacon beacon = CounterfactualBeacon(proxy);

        bool stale = false;
        if (_logStaleAddr("signer", beacon.signer(), expected.signer)) stale = true;
        if (_logStaleAddr("spokePool", beacon.spokePool(), expected.spokePool)) stale = true;
        if (_logStaleAddr("wrappedNativeToken", beacon.wrappedNativeToken(), expected.wrappedNativeToken)) {
            stale = true;
        }
        if (_logStaleAddr("nativeToken", beacon.nativeToken(), expected.nativeToken)) stale = true;
        if (_logStaleAddr("cctpSrcPeriphery", beacon.cctpSrcPeriphery(), expected.cctpSrcPeriphery)) stale = true;
        if (_logStaleAddr("cctpTokenMessenger", beacon.cctpTokenMessenger(), expected.cctpTokenMessenger)) {
            stale = true;
        }
        if (_logStaleUint("cctpSourceDomain", beacon.cctpSourceDomain(), expected.cctpSourceDomain)) stale = true;
        if (_logStaleAddr("oftSrcPeriphery", beacon.oftSrcPeriphery(), expected.oftSrcPeriphery)) stale = true;
        if (_logStaleUint("oftSrcEid", beacon.oftSrcEid(), expected.oftSrcEid)) stale = true;
        if (_logStaleAddr("usdc", beacon.usdc(), expected.usdc)) stale = true;
        if (_logStaleAddr("usdt", beacon.usdt(), expected.usdt)) stale = true;
        if (
            _logStaleUint("usdcCctpMaxExecutionFee", beacon.usdcCctpMaxExecutionFee(), expected.usdcCctpMaxExecutionFee)
        ) stale = true;
        if (_logStaleUint("usdtOftMaxExecutionFee", beacon.usdtOftMaxExecutionFee(), expected.usdtOftMaxExecutionFee))
            stale = true;
        if (
            _logStaleUint(
                "usdcSpokePoolMaxExecutionFee",
                beacon.usdcSpokePoolMaxExecutionFee(),
                expected.usdcSpokePoolMaxExecutionFee
            )
        ) stale = true;
        if (
            _logStaleUint(
                "usdtSpokePoolMaxExecutionFee",
                beacon.usdtSpokePoolMaxExecutionFee(),
                expected.usdtSpokePoolMaxExecutionFee
            )
        ) stale = true;
        if (
            _logStaleUint(
                "wethSpokePoolMaxExecutionFee",
                beacon.wethSpokePoolMaxExecutionFee(),
                expected.wethSpokePoolMaxExecutionFee
            )
        ) stale = true;

        if (stale) {
            console.log("--------------------------------------------");
            console.log("WARNING: the beacon implementation's baked chain config is stale.");
            console.log("Routes using the mismatched fields will revert RouteNotConfigured until the");
            console.log("registry is UUPS-upgraded: deploy `new CounterfactualBeacon(<current cfg>)` and");
            console.log('call `CounterfactualBeacon(proxy).upgradeToAndCall(newImpl, "")` as owner.');
            console.log("--------------------------------------------");
        } else {
            console.log("Beacon chain config: matches current resolvers");
        }
    }

    function _logStaleAddr(string memory field, address actual, address expected) internal view returns (bool) {
        if (actual == expected) return false;
        console.log("  stale beacon.%s: actual=%s expected=%s", field, actual, expected);
        return true;
    }

    function _logStaleUint(string memory field, uint256 actual, uint256 expected) internal view returns (bool) {
        if (actual == expected) return false;
        console.log("  stale beacon.%s: actual=%d expected=%d", field, actual, expected);
        return true;
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
        // Append `|| true` so non-fatal failures (e.g. etherscan verification timeout) don't make ffi revert
        // and halt subsequent deployments.
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
