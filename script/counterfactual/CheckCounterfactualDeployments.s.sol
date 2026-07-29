// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { console } from "forge-std/console.sol";
import { CounterfactualConfig } from "./CounterfactualConfig.sol";
import { CheckUtils } from "./CheckUtils.sol";
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
//     deployed-addresses.json (spokePool, wrappedNativeToken, cctp/oft periphery + domain/eid, usdc, usdt, wbtc),
//     plus a manual review of the fee `signer`.
//
// Owner/directWithdrawer are cross-referenced against config.toml's `ownerAndDirectWithdrawer` AND the
// chain's actually-deployed governance Safe (the `Safe` entry in deployed-addresses.json, generated from
// broadcast/DeploySafe.s.sol) for an independent second opinion.
//
// Before the per-chain forks, a registry-only cross-chain PARITY pass asserts every chain-identical
// contract (beacon proxy, dispatcher, factory, leaves, AdminWithdrawManager, WithdrawImplementation)
// sits at the SAME address on every config.toml chain — divergence means a deploy ran under the wrong
// profile/salt or a redeploy hasn't reached every chain yet. Tron is excluded (Tron solc fork ⇒
// different CREATE2 addresses by design) and beacon IMPLEMENTATIONS are exempt (per-chain by design).
//
// Freshly deployed (not-yet-live) beacon implementations are verified separately by
// CheckCounterfactualBeaconImpls.s.sol.
//
// Output prefixes for easy grep: [PASS] / [FAIL] / [REVIEW] / [INFO] (see CheckUtils).
//
// How to run:
//   source .env
//   FOUNDRY_PROFILE=counterfactual forge script \
//     script/counterfactual/CheckCounterfactualDeployments.s.sol:CheckCounterfactualDeployments \
//     --rpc-url $NODE_URL_1 --ffi -vvvv
contract CheckCounterfactualDeployments is CounterfactualConfig, CheckUtils {
    function run() external {
        _loadConfig(CONFIG_PATH, false);
        _loadDeployedAddresses();

        _checkCrossChainParity();

        uint256[] memory chains = config.getChainIds();
        for (uint256 i = 0; i < chains.length; i++) {
            uint256 chainId = chains[i];
            // Skip the synthetic `[0]` globals section in config.toml (holds the deploy salt, not a real chain).
            if (chainId == GLOBALS_CHAIN_ID) continue;
            // Skip Tron: forge cannot fork it (its RPC lacks standard methods and the failure surfaces in
            // selectFork, outside the try below). Tron deployments are verified via script/tron/ tooling.
            if (chainId == 728126428) {
                _info("Tron", "skipped: forge cannot fork Tron (verify via script/tron/ tooling)");
                continue;
            }
            try vm.createFork(config.getRpcUrl(chainId)) returns (uint256 forkId) {
                vm.selectFork(forkId);
                _checkChain(chainId);
            } catch {
                _fail(string.concat("Chain ", vm.toString(chainId)), "fork", "RPC unreachable or incompatible");
            }
        }

        _printSummary();
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

    // --- Cross-chain address parity (registry-only; runs before any fork) ---

    /// @dev Every CREATE2-deployed counterfactual contract must sit at the SAME address on every
    ///      config.toml chain (that is the whole point of the deterministic deploy). Beacon
    ///      IMPLEMENTATIONS are exempt (per-chain immutable config by design; they never appear in
    ///      deployed-addresses.json under a shared name) and Tron is excluded (Tron solc fork ⇒
    ///      different bytecode ⇒ different CREATE2 addresses, see script/tron/README.md). Chains
    ///      missing a contract entirely are skipped here — per-chain presence checks report those.
    function _checkCrossChainParity() internal {
        console.log("");
        console.log("## Cross-chain address parity (Tron excluded; beacon impls per-chain by design)");

        string[7] memory names = [
            string("CounterfactualBeacon"), // the address-stable proxy, not the per-chain impl
            "CounterfactualDeposit",
            "CounterfactualDepositFactory",
            "WithdrawImplementation",
            "AdminWithdrawManager",
            "CounterfactualDepositSpokePool",
            "CounterfactualDepositVanillaCCTP"
        ];
        for (uint256 i = 0; i < names.length; i++) _checkParityOf(names[i]);
        // Optional leaves: only deployed where the route exists; non-zero entries must still agree.
        _checkParityOf("CounterfactualDepositCCTP");
        _checkParityOf("CounterfactualDepositOFT");
    }

    function _checkParityOf(string memory name) internal {
        uint256[] memory chains = config.getChainIds();
        address firstAddr;
        uint256 present;
        bool diverged;
        for (uint256 i = 0; i < chains.length; i++) {
            uint256 chainId = chains[i];
            if (chainId == GLOBALS_CHAIN_ID || chainId == 728126428) continue; // globals section / Tron
            address addr = _getDeployed(name, chainId);
            if (addr == address(0)) continue;
            present++;
            if (firstAddr == address(0)) {
                firstAddr = addr;
            } else if (addr != firstAddr) {
                diverged = true;
                _fail(
                    name,
                    "parity",
                    string.concat(
                        "chain ",
                        vm.toString(chainId),
                        ": ",
                        vm.toString(addr),
                        " != ",
                        vm.toString(firstAddr),
                        " (first seen)"
                    )
                );
            }
        }
        if (present == 0) {
            _info(name, "parity skipped (not deployed on any chain)");
        } else if (!diverged) {
            _pass(name, "parity", string.concat(vm.toString(firstAddr), " on ", vm.toString(present), " chains"));
        }
    }

    // --- Bytecode-only contracts (chain-identical; presence is all we verify on-chain) ---

    function _checkBytecodeContracts(uint256 chainId) internal {
        // On Tron the deploy script uses `CounterfactualDepositSpokePoolTr` (Tron USDT's non-standard
        // `transfer` return), recorded under that name. Match that branch so a correct Tron deploy isn't
        // read as "missing".
        string memory spokePoolImpl = chainId == 728126428
            ? string("CounterfactualDepositSpokePoolTr")
            : string("CounterfactualDepositSpokePool");
        string[5] memory names = [
            string("CounterfactualBeacon"),
            "CounterfactualDeposit",
            "CounterfactualDepositFactory",
            "WithdrawImplementation",
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

        // CCTP / OFT / vanilla-CCTP leaf impls are only deployed where the route is configured
        // (gates mirror `_validateDeclaredSupport`'s flag semantics).
        _checkOptionalLeaf(
            "CounterfactualDepositCCTP",
            chainId,
            hasCctpDomain(chainId) && _getCctpPeriphery(chainId) != address(0)
        );
        _checkOptionalLeaf("CounterfactualDepositVanillaCCTP", chainId, _getCctpTokenMessenger(chainId) != address(0));
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

        // usdce vs constants.json (0 when absent or aliasing native usdc; reverts on pre-usdce impls)
        _assertAddrEq("CounterfactualBeacon", "usdce", beacon.usdce(), _getUsdce(chainId));

        // usdt vs constants.json (best-effort; 0 when not present)
        _assertAddrEq("CounterfactualBeacon", "usdt", beacon.usdt(), _getUsdt(chainId));

        // wbtc vs constants.json (0 when not present)
        _assertAddrEq("CounterfactualBeacon", "wbtc", beacon.wbtc(), _getWbtc(chainId));

        // weth vs constants.json (canonical WETH ERC-20, not the wrapped gas token; 0 when not present)
        _assertAddrEq("CounterfactualBeacon", "weth", beacon.weth(), _getWeth(chainId));

        // Per-(token, bridge) execution-fee caps vs config.toml — the exact resolver + sharing rule
        // `_buildChainConfig` bakes from (bridge types share the token's `<token>MaxExecutionFee` value;
        // 0 when the token is unset on this chain).
        uint256 usdcCap = _maxExecutionFee("usdcMaxExecutionFee", _getUsdc(chainId));
        uint256 usdtCap = _maxExecutionFee("usdtMaxExecutionFee", _getUsdt(chainId));
        _assertUintEq("CounterfactualBeacon", "usdcCctpMaxExecutionFee", beacon.usdcCctpMaxExecutionFee(), usdcCap);
        _assertUintEq("CounterfactualBeacon", "usdtOftMaxExecutionFee", beacon.usdtOftMaxExecutionFee(), usdtCap);
        _assertUintEq(
            "CounterfactualBeacon",
            "usdcSpokePoolMaxExecutionFee",
            beacon.usdcSpokePoolMaxExecutionFee(),
            usdcCap
        );
        _assertUintEq(
            "CounterfactualBeacon",
            "usdtSpokePoolMaxExecutionFee",
            beacon.usdtSpokePoolMaxExecutionFee(),
            usdtCap
        );
        _assertUintEq(
            "CounterfactualBeacon",
            "usdceSpokePoolMaxExecutionFee",
            beacon.usdceSpokePoolMaxExecutionFee(),
            _maxExecutionFee("usdceMaxExecutionFee", _getUsdce(chainId))
        );
        _assertUintEq(
            "CounterfactualBeacon",
            "wethSpokePoolMaxExecutionFee",
            beacon.wethSpokePoolMaxExecutionFee(),
            _maxExecutionFee("wethMaxExecutionFee", _getWeth(chainId))
        );
        // wbtc cap vs config.toml (same resolver the deploy script bakes from; 0 when wbtc unset)
        _assertUintEq(
            "CounterfactualBeacon",
            "wbtcSpokePoolMaxExecutionFee",
            beacon.wbtcSpokePoolMaxExecutionFee(),
            _maxExecutionFee("wbtcMaxExecutionFee", _getWbtc(chainId))
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
        // pendingOwner: zero is the healthy steady state (no transfer in flight); only a nonzero value
        // needs eyes — it means an Ownable2Step handoff is initiated but unaccepted.
        address pendingOwner = ownableBeacon.pendingOwner();
        if (pendingOwner == address(0)) {
            _pass("CounterfactualBeacon", "pendingOwner", "none (no transfer in flight)");
        } else {
            _reviewWithMultisig("CounterfactualBeacon", "pendingOwner", pendingOwner, configOwner, multisig);
        }
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

    /// @dev Bridged USDC.e, only where distinct from native USDC (mirrors CounterfactualConfig._resolveUsdce).
    function _getUsdce(uint256 chainId) internal view returns (address) {
        string memory path = string.concat(".USDCe.", vm.toString(chainId));
        if (!vm.keyExists(file, path)) return address(0);
        address usdce = vm.parseJsonAddress(file, path);
        return usdce == _getUsdc(chainId) ? address(0) : usdce;
    }

    function _getUsdt(uint256 chainId) internal view returns (address) {
        string memory path = string.concat(".USDT.", vm.toString(chainId));
        if (vm.keyExists(file, path)) return vm.parseJsonAddress(file, path);
        return address(0);
    }

    function _getWbtc(uint256 chainId) internal view returns (address) {
        string memory path = string.concat(".WBTC.", vm.toString(chainId));
        if (vm.keyExists(file, path)) return vm.parseJsonAddress(file, path);
        return address(0);
    }

    function _getWeth(uint256 chainId) internal view returns (address) {
        string memory path = string.concat(".WETH.", vm.toString(chainId));
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

    /// @dev This chain's governance Safe as actually deployed — the `Safe` entry in
    ///      deployed-addresses.json, generated from broadcast/DeploySafe.s.sol/<chainId>. address(0)
    ///      when no Safe has been deployed on the chain (reported as such, never silently substituted).
    function _getMultisig(uint256 chainId) internal view returns (address) {
        return _getDeployed("Safe", chainId);
    }

    // --- Logging helpers (shared ones live in CheckUtils) ---

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
            multisig == address(0)
                ? string("           deployed Safe: none on this chain (broadcast/DeploySafe.s.sol)")
                : string.concat(
                    "           deployed Safe: ",
                    vm.toString(multisig),
                    actual == multisig ? unicode" ✓" : " MISMATCH"
                )
        );
        totalReview++;
    }
}
