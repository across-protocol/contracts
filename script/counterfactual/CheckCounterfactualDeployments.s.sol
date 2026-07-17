// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Script } from "forge-std/Script.sol";
import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";
import { CounterfactualConfig } from "./CounterfactualConfig.sol";
import { CounterfactualBeacon } from "../../contracts/periphery/counterfactual/CounterfactualBeacon.sol";
import { ICounterfactualBeacon } from "../../contracts/interfaces/ICounterfactualBeacon.sol";
import { AdminWithdrawManager } from "../../contracts/periphery/counterfactual/AdminWithdrawManager.sol";

// Verifies counterfactual contract deployments across all configured chains.
//
// All chain-specific values (bridge endpoints, fee signer, token addresses) live on the per-chain
// CounterfactualBeacon (read via `ICounterfactualBeacon` getters), and the leaf impls are byte-identical
// across chains. So:
//   - Leaf impls (CounterfactualDeposit dispatcher, CCTP/OFT/VanillaCCTP, SpokePool) get bytecode-only
//     presence checks.
//   - Chain-specific config is auto-checked by comparing the beacon's getters against constants.json /
//     deployed-addresses.json (spokePool, wrappedNativeToken, cctp/oft periphery + domain/eid, usdc, usdt),
//     plus a manual review of the fee `signer`.
//
// Owner/directWithdrawer are cross-referenced against config.toml AND
// script/mintburn/prod-readiness-multisigs.json for an independent second opinion.
//
// Output prefixes for easy grep:
//   [PASS]   - Auto-check passed
//   [FAIL]   - Auto-check failed (investigate!)
//   [REVIEW] - Manual review needed (always printed, never silently passed)
//   [INFO]   - Informational
//
// How to run:
//   source .env
//   FOUNDRY_PROFILE=counterfactual forge script \
//     script/counterfactual/CheckCounterfactualDeployments.s.sol:CheckCounterfactualDeployments \
//     --rpc-url $NODE_URL_1 --ffi -vvvv
contract CheckCounterfactualDeployments is Script, Test, CounterfactualConfig {
    string constant MULTISIGS_PATH = "script/mintburn/prod-readiness-multisigs.json";

    string multisigsJson;
    string deployedAddressesJson;

    uint256 totalPass;
    uint256 totalFail;
    uint256 totalReview;

    function run() external {
        _loadConfig(CONFIG_PATH, false);
        multisigsJson = vm.readFile(MULTISIGS_PATH);
        deployedAddressesJson = vm.readFile("broadcast/deployed-addresses.json");

        uint256[] memory chains = config.getChainIds();
        for (uint256 i = 0; i < chains.length; i++) {
            uint256 chainId = chains[i];
            try vm.createFork(config.getRpcUrl(chainId)) returns (uint256 forkId) {
                vm.selectFork(forkId);
                _checkChain(chainId);
            } catch {
                _fail(string.concat("Chain ", vm.toString(chainId)), "fork", "RPC unreachable or incompatible");
            }
        }

        console.log("============================================");
        console.log("SUMMARY: %s passed, %s failed, %s manual review", totalPass, totalFail, totalReview);
        console.log("============================================");

        require(totalFail == 0, "Some auto-checks FAILED");
    }

    // --- Per-chain entry ---

    function _checkChain(uint256 chainId) internal {
        string memory name = _getChainName(chainId);
        console.log("");
        console.log("## %s (Chain %s)", name, chainId);

        _checkBytecodeContracts(chainId);
        _checkBeaconConfig(chainId);
        _checkAdminWithdrawManager(chainId);
    }

    // --- Bytecode-only contracts (chain-identical; presence is all we verify on-chain) ---

    function _checkBytecodeContracts(uint256 chainId) internal {
        // On Tron the deploy script uses `CounterfactualDepositSpokePoolTr` (Tron USDT's non-standard
        // `transfer` return), recorded under that name. Match that branch so a correct Tron deploy isn't
        // read as "missing".
        string memory spokePoolImpl = chainId == 728126428
            ? string("CounterfactualDepositSpokePoolTr")
            : string("CounterfactualDepositSpokePool");
        string[6] memory names = [
            string("CounterfactualBeacon"),
            "CounterfactualDeposit",
            "CounterfactualDepositFactory",
            "WithdrawImplementation",
            "CounterfactualDepositVanillaCCTP",
            spokePoolImpl
        ];
        for (uint256 i = 0; i < names.length; i++) {
            address addr = _getDeployed(names[i], chainId);
            if (addr == address(0)) {
                _fail(names[i], "address", "not in deployed-addresses.json");
            } else if (addr.code.length == 0) {
                _fail(names[i], "bytecode", "no code on-chain");
            } else {
                _pass(names[i], "bytecode", "deployed");
            }
        }

        // CCTP / OFT leaf impls are only deployed where the route is configured.
        _checkOptionalLeaf(
            "CounterfactualDepositCCTP",
            chainId,
            hasCctpDomain(chainId) && _getCctpPeriphery(chainId) != address(0)
        );
        _checkOptionalLeaf(
            "CounterfactualDepositOFT",
            chainId,
            hasOftEid(chainId) && _getOftPeriphery(chainId) != address(0)
        );
    }

    /// @dev Presence check for an optional leaf: FAIL if expected-but-missing, PASS if present, else INFO.
    function _checkOptionalLeaf(string memory name, uint256 chainId, bool expected) internal {
        address addr = _getDeployed(name, chainId);
        if (addr == address(0)) {
            if (expected) {
                _fail(name, "deployment", "route supported + periphery exists, but not deployed");
            } else {
                _info(name, "skipped (not applicable on this chain)");
            }
        } else if (addr.code.length == 0) {
            _fail(name, "bytecode", "no code on-chain");
        } else {
            _pass(name, "bytecode", "deployed");
        }
    }

    // --- CounterfactualBeacon config (the single source of all chain-specific values) ---

    function _checkBeaconConfig(uint256 chainId) internal {
        address addr = _getDeployed("CounterfactualBeacon", chainId);
        if (addr == address(0)) {
            _fail("CounterfactualBeacon", "address", "not in deployed-addresses.json");
            return;
        }
        if (addr.code.length == 0) {
            _fail("CounterfactualBeacon", "bytecode", "no code on-chain");
            return;
        }

        ICounterfactualBeacon beacon = ICounterfactualBeacon(addr);

        // Verify the beacon's `implementation()` resolves to the dispatcher. A deploy that stops after the
        // proxy upgrade but before `setImplementation(dispatcher)` leaves the slot zero/stale, so every
        // counterfactual proxy resolves the wrong target — config getters can pass while no clone is executable.
        address dispatcher = _getDeployed("CounterfactualDeposit", chainId);
        if (dispatcher == address(0)) {
            _fail("CounterfactualBeacon", "implementation", "CounterfactualDeposit not in deployed-addresses.json");
        } else {
            _assertAddrEq("CounterfactualBeacon", "implementation", beacon.implementation(), dispatcher);
        }

        // spokePool vs deployed-addresses.json
        address expectedSpokePool = _getDeployed("SpokePool", chainId);
        if (expectedSpokePool != address(0)) {
            _assertAddrEq("CounterfactualBeacon", "spokePool", beacon.spokePool(), expectedSpokePool);
        } else {
            _review(
                "CounterfactualBeacon",
                "spokePool",
                beacon.spokePool(),
                address(0),
                "deployed-addresses.json (no entry)"
            );
        }

        // wrappedNativeToken vs constants.json
        {
            string memory wntKey = string.concat(".WRAPPED_NATIVE_TOKENS.", vm.toString(chainId));
            if (vm.keyExists(file, wntKey)) {
                _assertAddrEq(
                    "CounterfactualBeacon",
                    "wrappedNativeToken",
                    beacon.wrappedNativeToken(),
                    vm.parseJsonAddress(file, wntKey)
                );
            } else {
                _review(
                    "CounterfactualBeacon",
                    "wrappedNativeToken",
                    beacon.wrappedNativeToken(),
                    address(0),
                    "constants.json (no entry)"
                );
            }
        }

        // nativeToken vs constants.json: defaults to NATIVE_SENTINEL absent a `.NATIVE_TOKEN.<chainId>`
        // override (matches `_resolveNativeToken`). Mismatches mean an override changed without a redeploy.
        _assertAddrEq("CounterfactualBeacon", "nativeToken", beacon.nativeToken(), _getNativeToken(chainId));

        // cctpSrcPeriphery vs deployed-addresses.json
        _assertAddrEq(
            "CounterfactualBeacon",
            "cctpSrcPeriphery",
            beacon.cctpSrcPeriphery(),
            _getCctpPeriphery(chainId)
        );

        // cctpSourceDomain vs constants.json (0 when CCTP unsupported)
        _assertUintEq(
            "CounterfactualBeacon",
            "cctpSourceDomain",
            uint256(beacon.cctpSourceDomain()),
            hasCctpDomain(chainId) ? uint256(getCircleDomainId(chainId)) : 0
        );

        // cctpTokenMessenger vs constants.json (best-effort; 0 when not present)
        _assertAddrEq(
            "CounterfactualBeacon",
            "cctpTokenMessenger",
            beacon.cctpTokenMessenger(),
            _getCctpTokenMessenger(chainId)
        );

        // oftSrcPeriphery vs deployed-addresses.json
        _assertAddrEq("CounterfactualBeacon", "oftSrcPeriphery", beacon.oftSrcPeriphery(), _getOftPeriphery(chainId));

        // oftSrcEid vs constants.json (0 when OFT unsupported)
        _assertUintEq(
            "CounterfactualBeacon",
            "oftSrcEid",
            uint256(beacon.oftSrcEid()),
            hasOftEid(chainId) ? getOftEid(chainId) : 0
        );

        // usdc vs constants.json (0 when not present)
        _assertAddrEq("CounterfactualBeacon", "usdc", beacon.usdc(), _getUsdc(chainId));

        // usdt vs constants.json (best-effort; 0 when not present)
        _assertAddrEq("CounterfactualBeacon", "usdt", beacon.usdt(), _getUsdt(chainId));

        // Per-(token, bridge) execution-fee caps vs config.toml (0 when unset).
        _assertUintEq(
            "CounterfactualBeacon",
            "usdcCctpMaxExecutionFee",
            beacon.usdcCctpMaxExecutionFee(),
            _resolveFeeCap("usdcCctpMaxExecutionFee")
        );
        _assertUintEq(
            "CounterfactualBeacon",
            "usdtOftMaxExecutionFee",
            beacon.usdtOftMaxExecutionFee(),
            _resolveFeeCap("usdtOftMaxExecutionFee")
        );
        _assertUintEq(
            "CounterfactualBeacon",
            "usdcSpokePoolMaxExecutionFee",
            beacon.usdcSpokePoolMaxExecutionFee(),
            _resolveFeeCap("usdcSpokePoolMaxExecutionFee")
        );
        _assertUintEq(
            "CounterfactualBeacon",
            "usdtSpokePoolMaxExecutionFee",
            beacon.usdtSpokePoolMaxExecutionFee(),
            _resolveFeeCap("usdtSpokePoolMaxExecutionFee")
        );
        _assertUintEq(
            "CounterfactualBeacon",
            "wethSpokePoolMaxExecutionFee",
            beacon.wethSpokePoolMaxExecutionFee(),
            _resolveFeeCap("wethSpokePoolMaxExecutionFee")
        );

        // Manual review: signer (no second source)
        address configSigner = config.get("signer").toAddress();
        _review("CounterfactualBeacon", "signer", beacon.signer(), configSigner, "config.toml");

        // Manual review: owner — the beacon admin can UUPS-upgrade the registry and retarget every
        // counterfactual proxy, so it must end up on the per-chain multisig (Ownable2Step: a pending transfer
        // is not yet effective). `pendingOwner` is reported separately to distinguish "already on the
        // multisig" from "transfer initiated, awaiting acceptance".
        CounterfactualBeacon ownableBeacon = CounterfactualBeacon(addr);
        address configOwner = config.get("ownerAndDirectWithdrawer").toAddress();
        address multisig = _getMultisig(chainId);
        _reviewWithMultisig("CounterfactualBeacon", "owner", ownableBeacon.owner(), configOwner, multisig);
        _reviewWithMultisig(
            "CounterfactualBeacon",
            "pendingOwner",
            ownableBeacon.pendingOwner(),
            configOwner,
            multisig
        );
    }

    // --- AdminWithdrawManager ---

    function _checkAdminWithdrawManager(uint256 chainId) internal {
        address addr = _getDeployed("AdminWithdrawManager", chainId);
        if (addr == address(0)) {
            _fail("AdminWithdrawManager", "address", "not in deployed-addresses.json");
            return;
        }
        if (addr.code.length == 0) {
            _fail("AdminWithdrawManager", "bytecode", "no code on-chain");
            return;
        }

        AdminWithdrawManager awm = AdminWithdrawManager(addr);

        address configOwner = config.get("ownerAndDirectWithdrawer").toAddress();
        address configSigner = config.get("signer").toAddress();
        address multisig = _getMultisig(chainId);

        // Manual review: owner — cross-reference config.toml AND multisigs.json
        _reviewWithMultisig("AdminWithdrawManager", "owner", awm.owner(), configOwner, multisig);

        // Manual review: directWithdrawer — cross-reference config.toml AND multisigs.json
        _reviewWithMultisig("AdminWithdrawManager", "directWithdrawer", awm.directWithdrawer(), configOwner, multisig);

        // Manual review: signer (no second source)
        _review("AdminWithdrawManager", "signer", awm.signer(), configSigner, "config.toml");
    }

    // --- Cached deployed-addresses.json lookups ---

    function _getDeployed(string memory contractName, uint256 chainId) internal view returns (address) {
        string memory path = string.concat(
            '.chains["',
            vm.toString(chainId),
            '"].contracts["',
            contractName,
            '"].address'
        );
        if (vm.keyExists(deployedAddressesJson, path)) {
            return vm.parseJsonAddress(deployedAddressesJson, path);
        }
        return address(0);
    }

    function _getChainName(uint256 chainId) internal view returns (string memory) {
        string memory path = string.concat('.chains["', vm.toString(chainId), '"].chain_name');
        if (vm.keyExists(deployedAddressesJson, path)) {
            return vm.parseJsonString(deployedAddressesJson, path);
        }
        return string.concat("Chain ", vm.toString(chainId));
    }

    // --- Cached CCTP/OFT periphery lookups ---

    function _getCctpPeriphery(uint256 chainId) internal view returns (address) {
        address addr = _getDeployed("SponsoredCCTPSrcPeriphery", chainId);
        if (addr == address(0)) addr = _getDeployed("SponsoredCctpSrcPeriphery", chainId);
        return addr;
    }

    function _getOftPeriphery(uint256 chainId) internal view returns (address) {
        return _getDeployed("SponsoredOFTSrcPeriphery", chainId);
    }

    // --- Constants.json token / messenger lookups (mirror the resolvers in CounterfactualConfig) ---

    function _getCctpTokenMessenger(uint256 chainId) internal view returns (address) {
        string memory chainIdStr = vm.toString(chainId);
        string memory l2Path = string.concat(".L2_ADDRESS_MAP.", chainIdStr, ".cctpV2TokenMessenger");
        if (vm.keyExists(file, l2Path)) return vm.parseJsonAddress(file, l2Path);
        string memory l1Path = string.concat(".L1_ADDRESS_MAP.", chainIdStr, ".cctpV2TokenMessenger");
        if (vm.keyExists(file, l1Path)) return vm.parseJsonAddress(file, l1Path);
        return address(0);
    }

    function _getUsdc(uint256 chainId) internal view returns (address) {
        string memory path = string.concat(".USDC.", vm.toString(chainId));
        if (vm.keyExists(file, path)) return vm.parseJsonAddress(file, path);
        return address(0);
    }

    function _getUsdt(uint256 chainId) internal view returns (address) {
        string memory path = string.concat(".USDT.", vm.toString(chainId));
        if (vm.keyExists(file, path)) return vm.parseJsonAddress(file, path);
        return address(0);
    }

    /// @dev Mirrors `CounterfactualConfig._resolveNativeToken`: `.NATIVE_TOKEN.<chainId>` override wins, else
    ///      `NATIVE_SENTINEL` when a wrapped native token exists, else `address(0)` (avoiding the
    ///      sentinel-but-no-wrapper footgun).
    function _getNativeToken(uint256 chainId) internal view returns (address) {
        string memory path = string.concat(".NATIVE_TOKEN.", vm.toString(chainId));
        if (vm.keyExists(file, path)) return vm.parseJsonAddress(file, path);
        string memory wntPath = string.concat(".WRAPPED_NATIVE_TOKENS.", vm.toString(chainId));
        if (!vm.keyExists(file, wntPath)) return address(0);
        return NATIVE_SENTINEL;
    }

    // --- Multisig lookup ---

    function _getMultisig(uint256 chainId) internal view returns (address) {
        string memory path = string.concat(".", vm.toString(chainId));
        if (vm.keyExists(multisigsJson, path)) {
            return vm.parseJsonAddress(multisigsJson, path);
        }
        return vm.parseJsonAddress(multisigsJson, ".fallbackEOA");
    }

    // --- Logging helpers ---

    function _pass(string memory contract_, string memory field, string memory value) internal {
        console.log("[PASS]   %s.%s = %s", contract_, field, value);
        totalPass++;
    }

    function _fail(string memory contract_, string memory field, string memory detail) internal {
        console.log("[FAIL]   %s.%s: %s", contract_, field, detail);
        totalFail++;
    }

    function _info(string memory contract_, string memory detail) internal pure {
        console.log("[INFO]   %s: %s", contract_, detail);
    }

    function _assertAddrEq(string memory contract_, string memory field, address actual, address expected) internal {
        if (actual == expected) {
            _pass(contract_, field, vm.toString(actual));
        } else {
            console.log("[FAIL]   %s.%s", contract_, field);
            console.log("           actual:   %s", actual);
            console.log("           expected: %s", expected);
            totalFail++;
        }
    }

    function _assertUintEq(string memory contract_, string memory field, uint256 actual, uint256 expected) internal {
        if (actual == expected) {
            _pass(contract_, field, vm.toString(actual));
        } else {
            console.log("[FAIL]   %s.%s", contract_, field);
            console.log("           actual:   %s", actual);
            console.log("           expected: %s", expected);
            totalFail++;
        }
    }

    function _review(
        string memory contract_,
        string memory field,
        address actual,
        address configValue,
        string memory source
    ) internal {
        string memory tag = actual == configValue
            ? string.concat("matches ", source)
            : string.concat("MISMATCH vs ", source, ": ", vm.toString(configValue));
        console.log(string.concat("[REVIEW] ", contract_, ".", field, " = ", vm.toString(actual), " (", tag, ")"));
        totalReview++;
    }

    function _reviewWithMultisig(
        string memory contract_,
        string memory field,
        address actual,
        address configValue,
        address multisig
    ) internal {
        console.log("[REVIEW] %s.%s = %s", contract_, field, vm.toString(actual));
        console.log(
            string.concat(
                "           config.toml: ",
                vm.toString(configValue),
                actual == configValue ? unicode" ✓" : " MISMATCH"
            )
        );
        console.log(
            string.concat(
                "           multisigs.json: ",
                vm.toString(multisig),
                actual == multisig ? unicode" ✓" : " MISMATCH"
            )
        );
        totalReview++;
    }
}
