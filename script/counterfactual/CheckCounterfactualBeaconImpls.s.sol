// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { console } from "forge-std/console.sol";
import { ERC1967Utils } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { CounterfactualConfig } from "./CounterfactualConfig.sol";
import { CheckUtils } from "./CheckUtils.sol";
import {
    CounterfactualBeacon,
    CounterfactualChainConfig
} from "../../contracts/periphery/counterfactual/CounterfactualBeacon.sol";
import { ICounterfactualBeacon } from "../../contracts/interfaces/ICounterfactualBeacon.sol";
import { ITokenMessengerV2, ITokenMinter } from "../../contracts/external/interfaces/CCTPInterfaces.sol";

/// @dev Minimal fingerprint views. Each referenced contract exposes a getter whose value is knowable in
///      advance, so a matching answer confirms the address really is that kind of contract (a wrong or
///      stale address answers wrong, reverts, or returns empty).
interface ISpokePoolFingerprint {
    function chainId() external view returns (uint256);

    function wrappedNativeToken() external view returns (address);
}

interface ICctpSrcPeripheryFingerprint {
    function sourceDomain() external view returns (uint32);

    function cctpTokenMessenger() external view returns (address);

    function signer() external view returns (address);
}

interface IOftSrcPeripheryFingerprint {
    function SRC_EID() external view returns (uint32);

    function TOKEN() external view returns (address);

    function signer() external view returns (address);
}

/// @dev Throwaway harness deployed fresh on each fork so `_buildChainConfig`'s requires (missing fee cap,
///      declared-support flag mismatch, ...) can be try/caught per chain instead of aborting the whole run
///      (a `this.` self-call would trip forge's address(this)-in-script detection).
contract ChainConfigResolver is CounterfactualConfig {
    function build() external returns (CounterfactualChainConfig memory) {
        return _buildChainConfig();
    }
}

// Verifies freshly deployed chain-specific CounterfactualBeacon IMPLEMENTATIONS — the most recent
// `CounterfactualBeacon` in broadcast/DeployCounterfactualBeaconImpl.s.sol/<chainId>/run-latest.json —
// BEFORE the owner points the live beacon proxy at them (`upgradeToAndCall(newImpl, "")`), across all
// config.toml chains. Complements CheckCounterfactualDeployments.s.sol, which checks the LIVE proxy.
//
// Per chain:
//   - Impl safety: `proxiableUUID()` is the ERC1967 impl slot and direct `initialize` reverts
//     (initializers disabled on the bare impl).
//   - Every config getter vs a fresh `_buildChainConfig()` — the exact resolver the deploy script baked
//     from (constants.json + deployed-addresses.json + config.toml, including the `[N.bool]` declared
//     support flags). A mismatch means the sources moved since the impl was deployed: redeploy the impl.
//   - Tokens: on-chain `symbol()` of every configured token vs an expected-symbol allowlist; wrapped
//     native / ERC-20 gas tokens are surfaced for manual review (symbols vary per chain).
//   - Peripheries: an on-chain fingerprint view per referenced contract, cross-checked against the
//     impl's own values — SpokePool `chainId()`/`wrappedNativeToken()`, SponsoredCCTPSrcPeriphery
//     `sourceDomain()`/`cctpTokenMessenger()`, SponsoredOFTSrcPeriphery `SRC_EID()`/`TOKEN()`, and the
//     Circle TokenMessenger's `localMinter().burnLimitsPerMessage(usdc)`.
//   - Upgrade status: whether the live proxy already runs this impl; when pending, prints the
//     `upgradeToAndCall` multisig calldata and a [DIFF] of every getter the upgrade would change.
//
// Tron is skipped (impl deployed via script/tron/counterfactual/tron-deploy-counterfactual-beacon-impl.ts;
// forge cannot fork Tron). On ZK-stack chains, calls into era-VM-bytecode contracts (pre-interpreter
// SpokePool/tokens) cannot run under the local EVM fork — those degrade to [REVIEW] instead of [FAIL].
//
// Output prefixes for easy grep: [PASS] / [FAIL] / [REVIEW] / [DIFF] / [INFO] (see CheckUtils).
//
// How to run (--gas-limit: one EVM frame spans ~24 forks of JSON-cheatcode work, which outgrows the
// default gas limit):
//   source .env
//   FOUNDRY_PROFILE=counterfactual forge script \
//     script/counterfactual/CheckCounterfactualBeaconImpls.s.sol:CheckCounterfactualBeaconImpls \
//     --rpc-url $NODE_URL_1 --ffi --gas-limit 100000000000 -vvvv
contract CheckCounterfactualBeaconImpls is CounterfactualConfig, CheckUtils {
    string constant IMPL_SCRIPT = "DeployCounterfactualBeaconImpl.s.sol";
    uint256 constant TRON_CHAIN_ID = 728126428;

    ChainConfigResolver resolver;

    function run() external {
        _setUp();

        uint256[] memory chains = config.getChainIds();
        for (uint256 i = 0; i < chains.length; i++) {
            uint256 chainId = chains[i];
            // Skip the synthetic `[0]` globals section in config.toml (holds the deploy salt, not a real chain).
            if (chainId == GLOBALS_CHAIN_ID) continue;
            if (chainId == TRON_CHAIN_ID) {
                _info(
                    "Tron",
                    "skipped: impl deployed via script/tron/counterfactual/tron-deploy-counterfactual-beacon-impl.ts (forge cannot fork Tron)"
                );
                continue;
            }
            _forkAndCheck(chainId, address(0));
        }

        _printSummary();
    }

    /// @notice Checks SPECIFIC impl addresses (e.g. the targets of queued multisig upgrade txs) instead
    ///         of each chain's latest broadcast — everything else is the same battery of checks. A full
    ///         PASS means upgrading the proxy to that impl is exactly as safe as upgrading to the latest.
    ///
    ///   FOUNDRY_PROFILE=counterfactual forge script \
    ///     script/counterfactual/CheckCounterfactualBeaconImpls.s.sol:CheckCounterfactualBeaconImpls \
    ///     --sig "run(uint256[],address[])" "[1,10]" "[0x...,0x...]" \
    ///     --rpc-url $NODE_URL_1 --ffi --gas-limit 100000000000 -vvvv
    function run(uint256[] calldata chainIds, address[] calldata impls) external {
        require(chainIds.length == impls.length && chainIds.length != 0, "chainIds/impls length mismatch");
        _setUp();
        for (uint256 i = 0; i < chainIds.length; i++) {
            require(impls[i] != address(0), "impl is zero");
            _forkAndCheck(chainIds[i], impls[i]);
        }
        _printSummary();
    }

    function _setUp() internal {
        _loadCounterfactualConfig();
        _loadDeployedAddresses();

        // One resolver for the whole run, persistent across forks: constructing it re-reads the multi-MB
        // constants.json, which does not fit in the CREATE frame on low-block-gas-limit chains.
        // deployCode (not `new`) keeps the resolver's creation code out of this contract's bytecode —
        // inlining it overflows solc's assembler tag space ("Tag too large for reserved space").
        resolver = ChainConfigResolver(deployCode("CheckCounterfactualBeaconImpls.s.sol:ChainConfigResolver"));
        vm.makePersistent(address(resolver));
    }

    /// @param impl The impl to verify, or address(0) to resolve this chain's latest broadcast.
    function _forkAndCheck(uint256 chainId, address impl) internal {
        try vm.createFork(config.getRpcUrl(chainId)) returns (uint256 forkId) {
            vm.selectFork(forkId);
            _checkChain(chainId, impl);
        } catch {
            _fail(string.concat("Chain ", vm.toString(chainId)), "fork", "RPC unreachable or incompatible");
        }
    }

    // --- Per-chain entry ---

    function _checkChain(uint256 chainId, address impl) internal {
        console.log("");
        console.log("## %s (Chain %s)", _getChainName(chainId), chainId);

        address latest = getLatestBroadcastDeployment(IMPL_SCRIPT, "CounterfactualBeacon");
        if (impl == address(0)) {
            impl = latest;
            if (impl == address(0)) {
                _fail("BeaconImpl", "broadcast", "no DeployCounterfactualBeaconImpl broadcast for this chain");
                return;
            }
        }
        if (impl.code.length == 0) {
            _fail("BeaconImpl", "bytecode", string.concat("impl has no code on-chain: ", vm.toString(impl)));
            return;
        }
        _info("BeaconImpl", string.concat("checking impl ", vm.toString(impl)));
        if (impl != latest) {
            // An older impl is fine as long as every check below passes against CURRENT expected config;
            // note it so nobody assumes run-latest.json describes what is being verified (only the
            // fresh-proxy path in DeployCounterfactualBeacon consumes run-latest).
            _reviewNote(
                "BeaconImpl",
                string.concat("not this chain's latest broadcast impl (latest: ", vm.toString(latest), ")")
            );
        }

        // Probe before any direct (high-level) getter call: if the impl's code cannot execute under the
        // local EVM (e.g. deployed as era-VM bytecode), direct calls would revert the whole run.
        (bool readable, ) = _tryReadWord(impl, abi.encodeCall(ICounterfactualBeacon.signer, ()));
        if (!readable) {
            _failOrZkReview(chainId, "BeaconImpl", "getters", "unreadable under the local EVM");
            _checkUpgradeStatus(chainId, impl); // low-level reads only
            return;
        }

        _checkImplSafety(impl);

        // Re-resolve this chain's expected config with the deploy script's own resolver and diff every
        // getter. A resolution revert (flag mismatch, missing fee cap...) means the sources moved since
        // the impl deployed — the impl is stale relative to intent, so it's a FAIL either way.
        // Resolved in a separate harness contract so the requires can be try/caught (a `this.` self-call
        // would trip forge's address(this)-in-script detection).
        try resolver.build() returns (CounterfactualChainConfig memory expected) {
            _compareConfig(impl, expected);
        } catch Error(string memory reason) {
            _fail("BeaconImpl", "expectedConfig", reason);
        } catch {
            _fail("BeaconImpl", "expectedConfig", "config resolution reverted (revert strings stripped?)");
        }

        // Token/periphery checks run on the impl's ACTUAL values (low-level reads; getters missing on an
        // older impl read as 0 = route absent), so they hold for an impl of any vintage.
        CounterfactualChainConfig memory onchain = _readImplConfig(impl);
        _checkTokens(chainId, onchain);
        _checkPeripheries(chainId, onchain);
        _checkUpgradeStatus(chainId, impl);
    }

    /// @dev The impl's config via guarded reads; a missing/unreadable getter reads as 0 (fee caps are
    ///      omitted — the token/periphery checks don't use them).
    function _readImplConfig(address impl) internal view returns (CounterfactualChainConfig memory c) {
        c.signer = _readAddr(impl, ICounterfactualBeacon.signer.selector);
        c.spokePool = _readAddr(impl, ICounterfactualBeacon.spokePool.selector);
        c.wrappedNativeToken = _readAddr(impl, ICounterfactualBeacon.wrappedNativeToken.selector);
        c.nativeToken = _readAddr(impl, ICounterfactualBeacon.nativeToken.selector);
        c.cctpSrcPeriphery = _readAddr(impl, ICounterfactualBeacon.cctpSrcPeriphery.selector);
        c.cctpTokenMessenger = _readAddr(impl, ICounterfactualBeacon.cctpTokenMessenger.selector);
        c.cctpSourceDomain = uint32(_readUint(impl, ICounterfactualBeacon.cctpSourceDomain.selector));
        c.oftSrcPeriphery = _readAddr(impl, ICounterfactualBeacon.oftSrcPeriphery.selector);
        c.oftSrcEid = uint32(_readUint(impl, ICounterfactualBeacon.oftSrcEid.selector));
        c.usdc = _readAddr(impl, ICounterfactualBeacon.usdc.selector);
        c.usdce = _readAddr(impl, ICounterfactualBeacon.usdce.selector);
        c.usdt = _readAddr(impl, ICounterfactualBeacon.usdt.selector);
        c.wbtc = _readAddr(impl, ICounterfactualBeacon.wbtc.selector);
        c.weth = _readAddr(impl, ICounterfactualBeacon.weth.selector);
    }

    function _readAddr(address impl, bytes4 sel) internal view returns (address) {
        (bool ok, bytes32 w) = _tryReadWord(impl, abi.encodeWithSelector(sel));
        return ok ? _toAddr(w) : address(0);
    }

    function _readUint(address impl, bytes4 sel) internal view returns (uint256) {
        (bool ok, bytes32 w) = _tryReadWord(impl, abi.encodeWithSelector(sel));
        return ok ? uint256(w) : 0;
    }

    // --- Impl safety (a bare impl must be a UUPS target and reject direct initialization) ---

    function _checkImplSafety(address impl) internal {
        (bool ok, bytes32 uuid) = _tryReadWord(impl, abi.encodeCall(UUPSUpgradeable.proxiableUUID, ()));
        if (ok && uuid == ERC1967Utils.IMPLEMENTATION_SLOT) {
            _pass("BeaconImpl", "proxiableUUID", "ERC1967 implementation slot");
        } else if (ok) {
            _fail("BeaconImpl", "proxiableUUID", vm.toString(uuid));
        } else {
            _fail("BeaconImpl", "proxiableUUID", "call failed (not a UUPS implementation?)");
        }

        // The constructor calls _disableInitializers, so direct initialization (= anyone taking ownership
        // of the bare impl) must revert. State change is simulated on the fork only — never broadcast.
        try CounterfactualBeacon(impl).initialize(address(0xdead), address(0), bytes32(0)) {
            _fail("BeaconImpl", "initialize", "direct initialization SUCCEEDED - initializers not disabled");
        } catch {
            _pass("BeaconImpl", "initialize", "reverts (initializers disabled)");
        }
    }

    // --- Getter-by-getter compare vs the deploy-time resolver ---

    /// @dev Low-level reads so an impl of any vintage can be checked — an impl predating a getter (e.g.
    ///      pre-usdce) reports "[FAIL] getter missing" instead of hard-reverting the run.
    function _compareConfig(address impl, CounterfactualChainConfig memory e) internal {
        (bytes4[22] memory sels, string[22] memory names) = _configGetters();
        bytes32[22] memory expected = _expectedWords(e);
        for (uint256 i = 0; i < sels.length; i++) {
            (bool ok, bytes32 actual) = _tryReadWord(impl, abi.encodeWithSelector(sels[i]));
            if (!ok) {
                _fail("BeaconImpl", names[i], "getter missing/unreadable on this impl");
            } else if (actual != expected[i]) {
                console.log("[FAIL]   BeaconImpl.%s", names[i]);
                console.log("           actual:   %s", vm.toString(actual));
                console.log("           expected: %s", vm.toString(expected[i]));
                totalFail++;
            } else {
                _pass("BeaconImpl", names[i], vm.toString(actual));
            }
        }
    }

    /// @dev The expected struct as raw words, in `_configGetters` order.
    function _expectedWords(CounterfactualChainConfig memory e) internal pure returns (bytes32[22] memory w) {
        w[0] = _addrWord(e.signer);
        w[1] = _addrWord(e.spokePool);
        w[2] = _addrWord(e.wrappedNativeToken);
        w[3] = _addrWord(e.nativeToken);
        w[4] = _addrWord(e.cctpSrcPeriphery);
        w[5] = _addrWord(e.cctpTokenMessenger);
        w[6] = bytes32(uint256(e.cctpSourceDomain));
        w[7] = _addrWord(e.oftSrcPeriphery);
        w[8] = bytes32(uint256(e.oftSrcEid));
        w[9] = _addrWord(e.usdc);
        w[10] = _addrWord(e.usdce);
        w[11] = _addrWord(e.usdt);
        w[12] = _addrWord(e.wbtc);
        w[13] = _addrWord(e.weth);
        w[14] = bytes32(e.usdcCctpMaxExecutionFee);
        w[15] = bytes32(e.usdcCctpMaxFeeBps);
        w[16] = bytes32(e.usdtOftMaxExecutionFee);
        w[17] = bytes32(e.usdcSpokePoolMaxExecutionFee);
        w[18] = bytes32(e.usdceSpokePoolMaxExecutionFee);
        w[19] = bytes32(e.usdtSpokePoolMaxExecutionFee);
        w[20] = bytes32(e.wethSpokePoolMaxExecutionFee);
        w[21] = bytes32(e.wbtcSpokePoolMaxExecutionFee);
    }

    function _addrWord(address a) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(a)));
    }

    // --- On-chain token identity: symbol() of every configured token vs an expected-symbol allowlist ---

    function _checkTokens(uint256 chainId, CounterfactualChainConfig memory c) internal {
        _checkTokenSymbol(chainId, "usdc", c.usdc, [string("USDC"), "", "", ""]);
        _checkTokenSymbol(chainId, "usdce", c.usdce, [string("USDC.e"), "USDC", "USDbC", ""]);
        _checkTokenSymbol(chainId, "usdt", c.usdt, USDT_SYMBOLS());
        _checkTokenSymbol(chainId, "wbtc", c.wbtc, [string("WBTC"), "BTCB", "", ""]);
        _checkTokenSymbol(chainId, "weth", c.weth, [string("WETH"), "ETH", "", ""]);

        // Wrapped native varies per chain (WETH/WBNB/WPOL/WHYPE/...) — always surfaced for manual eyeball.
        _reviewTokenSymbol(
            chainId,
            "wrappedNativeToken",
            c.wrappedNativeToken,
            "confirm it wraps this chain's gas token"
        );

        // An ERC-20 `nativeToken` override (non-sentinel, e.g. USDC-as-gas on ARC) — surfaced likewise.
        address nat = c.nativeToken;
        if (nat != NATIVE_SENTINEL) {
            _reviewTokenSymbol(chainId, "nativeToken", nat, "confirm it is this chain's gas-equivalent ERC-20");
        }
    }

    /// @dev USDT-family symbols: canonical, USDT0/USD₮0 (LayerZero-era Tether), Avalanche's "USDt".
    function USDT_SYMBOLS() internal pure returns (string[4] memory) {
        return [string("USDT"), unicode"USD₮0", "USDT0", "USDt"];
    }

    function _checkTokenSymbol(uint256 chainId, string memory field, address token, string[4] memory allowed) internal {
        (bool ok, string memory sym) = _readTokenSymbol(chainId, field, token);
        if (!ok) return;
        bytes32 h = keccak256(bytes(sym));
        for (uint256 i = 0; i < allowed.length; i++) {
            if (bytes(allowed[i]).length != 0 && h == keccak256(bytes(allowed[i]))) {
                _pass(field, "symbol", sym);
                return;
            }
        }
        _fail(field, "symbol", string.concat("unexpected symbol: ", sym));
    }

    /// @dev Symbol lookup for tokens with no universal expected symbol — always a [REVIEW], never a PASS.
    function _reviewTokenSymbol(uint256 chainId, string memory field, address token, string memory hint) internal {
        (bool ok, string memory sym) = _readTokenSymbol(chainId, field, token);
        if (ok) _reviewNote(field, string.concat("symbol = ", sym, " - ", hint));
    }

    /// @dev Reads `symbol()` with the failure modes reported; ok=false when there is nothing to compare.
    function _readTokenSymbol(
        uint256 chainId,
        string memory field,
        address token
    ) internal returns (bool ok, string memory sym) {
        if (token == address(0)) return (false, "");
        // Era-VM accounts can read as code-less on a local EVM fork, so this too is only conclusive
        // on non-ZK chains.
        if (token.code.length == 0) {
            _failOrZkReview(chainId, field, "code", "no code at token address");
            return (false, "");
        }
        // Has code but symbol() unreadable: exotic runtimes (era-VM accounts, TIP-20 system tokens) fail
        // under the local EVM even for correct tokens, so this is never conclusive — always manual review.
        (ok, sym) = _trySymbol(token);
        if (!ok) _reviewNote(field, "symbol() unreadable under the local EVM - verify the token manually");
    }

    // --- Periphery fingerprints, cross-checked against the impl's own values ---

    function _checkPeripheries(uint256 chainId, CounterfactualChainConfig memory c) internal {
        address configSigner = config.get("signer").toAddress();
        bool ok;
        bytes32 w;

        address sp = c.spokePool;
        if (sp != address(0)) {
            (ok, w) = _fingerprint(
                chainId,
                "SpokePool",
                "chainId()",
                sp,
                abi.encodeCall(ISpokePoolFingerprint.chainId, ())
            );
            if (ok) {
                if (uint256(w) == block.chainid) _pass("SpokePool", "chainId()", vm.toString(uint256(w)));
                else _fail("SpokePool", "chainId()", string.concat("returned ", vm.toString(uint256(w))));
            }
            // The native (msg.value) route wraps into the beacon's wrappedNativeToken and deposits it into
            // the SpokePool, whose msg.value path requires inputToken == its own wrappedNativeToken — a
            // mismatch bricks the route.
            if (c.wrappedNativeToken != address(0)) {
                (ok, w) = _fingerprint(
                    chainId,
                    "SpokePool",
                    "wrappedNativeToken",
                    sp,
                    abi.encodeCall(ISpokePoolFingerprint.wrappedNativeToken, ())
                );
                if (ok) _assertAddrEq("SpokePool", "wrappedNativeToken", _toAddr(w), c.wrappedNativeToken);
            }
        }

        address cctpP = c.cctpSrcPeriphery;
        if (cctpP != address(0)) {
            (ok, w) = _fingerprint(
                chainId,
                "SponsoredCCTPSrcPeriphery",
                "sourceDomain",
                cctpP,
                abi.encodeCall(ICctpSrcPeripheryFingerprint.sourceDomain, ())
            );
            if (ok) _assertUintEq("SponsoredCCTPSrcPeriphery", "sourceDomain", uint256(w), c.cctpSourceDomain);
            if (c.cctpTokenMessenger != address(0)) {
                (ok, w) = _fingerprint(
                    chainId,
                    "SponsoredCCTPSrcPeriphery",
                    "cctpTokenMessenger",
                    cctpP,
                    abi.encodeCall(ICctpSrcPeripheryFingerprint.cctpTokenMessenger, ())
                );
                if (ok)
                    _assertAddrEq("SponsoredCCTPSrcPeriphery", "cctpTokenMessenger", _toAddr(w), c.cctpTokenMessenger);
            }
            _reviewPeripherySigner("SponsoredCCTPSrcPeriphery", cctpP, configSigner);
        }

        address oftP = c.oftSrcPeriphery;
        if (oftP != address(0)) {
            (ok, w) = _fingerprint(
                chainId,
                "SponsoredOFTSrcPeriphery",
                "SRC_EID",
                oftP,
                abi.encodeCall(IOftSrcPeripheryFingerprint.SRC_EID, ())
            );
            if (ok) _assertUintEq("SponsoredOFTSrcPeriphery", "SRC_EID", uint256(w), c.oftSrcEid);
            // Single-token OFT periphery (USDT0 today). The OFT leaf takes its input token from the
            // periphery's own TOKEN(), which may legitimately differ from beacon.usdt (e.g. Optimism:
            // USDT0 is a separate contract from legacy USDT) — so symbol-check TOKEN() and surface the
            // relationship instead of asserting equality.
            (ok, w) = _fingerprint(
                chainId,
                "SponsoredOFTSrcPeriphery",
                "TOKEN",
                oftP,
                abi.encodeCall(IOftSrcPeripheryFingerprint.TOKEN, ())
            );
            if (ok) _checkOftToken(chainId, _toAddr(w), c.usdt);
            _reviewPeripherySigner("SponsoredOFTSrcPeriphery", oftP, configSigner);
        }

        // Vanilla CCTP: the Circle TokenMessenger's minter must exist and recognize usdc as burnable.
        address messenger = c.cctpTokenMessenger;
        if (messenger != address(0)) {
            (ok, w) = _fingerprint(
                chainId,
                "cctpTokenMessenger",
                "localMinter",
                messenger,
                abi.encodeCall(ITokenMessengerV2.localMinter, ())
            );
            if (ok) {
                address minter = _toAddr(w);
                if (minter == address(0)) {
                    _fail("cctpTokenMessenger", "localMinter", "zero address");
                } else if (c.usdc != address(0)) {
                    (ok, w) = _fingerprint(
                        chainId,
                        "cctpTokenMessenger",
                        "usdcBurnLimit",
                        minter,
                        abi.encodeCall(ITokenMinter.burnLimitsPerMessage, (c.usdc))
                    );
                    if (ok) {
                        if (uint256(w) > 0) _pass("cctpTokenMessenger", "usdcBurnLimit", vm.toString(uint256(w)));
                        else
                            _fail(
                                "cctpTokenMessenger",
                                "usdcBurnLimit",
                                "0 - minter does not recognize usdc as burnable"
                            );
                    }
                } else {
                    _pass("cctpTokenMessenger", "localMinter", vm.toString(minter));
                }
            }
        }
    }

    /// @dev Low-level fingerprint read; reports the failure itself and returns ok=false so callers just
    ///      guard on `ok`.
    function _fingerprint(
        uint256 chainId,
        string memory contract_,
        string memory field,
        address target,
        bytes memory data
    ) internal returns (bool ok, bytes32 word) {
        (ok, word) = _tryReadWord(target, data);
        if (!ok) _failOrZkReview(chainId, contract_, field, "call failed (wrong contract?)");
    }

    function _toAddr(bytes32 word) internal pure returns (address) {
        return address(uint160(uint256(word)));
    }

    function _checkOftToken(uint256 chainId, address oftToken, address usdt) internal {
        _checkTokenSymbol(chainId, "SponsoredOFTSrcPeriphery.TOKEN", oftToken, USDT_SYMBOLS());
        if (oftToken != usdt) {
            _reviewNote(
                "SponsoredOFTSrcPeriphery",
                string.concat(
                    "TOKEN() = ",
                    vm.toString(oftToken),
                    " differs from beacon.usdt - the OFT route moves this token, not usdt; confirm intended"
                )
            );
        }
    }

    /// @dev The sponsored peripheries have their own quote `signer` (a separate system from the beacon's
    ///      counterfactual fee signer) — surfaced for manual review, with a hint when the two coincide.
    function _reviewPeripherySigner(string memory contract_, address periphery, address configSigner) internal {
        (bool ok, bytes32 w) = _tryReadWord(periphery, abi.encodeCall(ICctpSrcPeripheryFingerprint.signer, ()));
        if (!ok) {
            _reviewNote(contract_, "signer() unreadable - verify the quote signer manually");
            return;
        }
        address s = _toAddr(w);
        _reviewNote(
            contract_,
            string.concat(
                "signer = ",
                vm.toString(s),
                s == configSigner
                    ? " (= counterfactual fee signer)"
                    : " (differs from counterfactual fee signer - separate quote signer, confirm intended)"
            )
        );
    }

    // --- Upgrade status vs the live beacon proxy ---

    function _checkUpgradeStatus(uint256 chainId, address impl) internal {
        address proxy = _getDeployed("CounterfactualBeacon", chainId);
        if (proxy == address(0) || proxy.code.length == 0) {
            _info(
                "BeaconProxy",
                "no live beacon proxy (fresh chain: DeployCounterfactualBeacon will pick up this impl)"
            );
            return;
        }
        address current = address(uint160(uint256(vm.load(proxy, ERC1967Utils.IMPLEMENTATION_SLOT))));
        if (current == impl) {
            _pass("BeaconProxy", "implSlot", "already upgraded to this impl");
            return;
        }
        _info("BeaconProxy", string.concat("upgrade PENDING - live impl is ", vm.toString(current)));
        console.log("[INFO]   upgrade tx: to   = %s", proxy);
        console.log(
            "[INFO]   upgrade tx: data = %s",
            vm.toString(abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (impl, bytes(""))))
        );
        _diffAgainstLiveProxy(proxy, impl);
    }

    /// @dev Prints a [DIFF] line for every config getter the pending upgrade would change — the exact
    ///      review surface for the multisig signers. Values print as raw bytes32 words (addresses are
    ///      left-padded, uints big-endian).
    function _diffAgainstLiveProxy(address proxy, address impl) internal {
        (bytes4[22] memory sels, string[22] memory names) = _configGetters();
        uint256 diffs;
        for (uint256 i = 0; i < sels.length; i++) {
            (bool okLive, bytes32 liveV) = _tryReadWord(proxy, abi.encodeWithSelector(sels[i]));
            (bool okNew, bytes32 newV) = _tryReadWord(impl, abi.encodeWithSelector(sels[i]));
            if (!okNew) {
                _fail("BeaconImpl", names[i], "getter unreadable on the new impl");
                continue;
            }
            if (!okLive) {
                console.log("[DIFF]   %s: <no getter on live impl> -> %s", names[i], vm.toString(newV));
                diffs++;
                totalReview++;
            } else if (liveV != newV) {
                console.log("[DIFF]   %s: %s -> %s", names[i], vm.toString(liveV), vm.toString(newV));
                diffs++;
                totalReview++;
            }
        }
        if (diffs == 0) {
            _info("BeaconImpl", "upgrade is a config no-op: new impl returns values identical to the live beacon");
        }
    }

    /// @dev Every config getter on ICounterfactualBeacon (excludes `implementation`/`upgradeRoot`, which
    ///      read proxy storage and are meaningless on a bare impl).
    function _configGetters() internal pure returns (bytes4[22] memory sels, string[22] memory names) {
        // Element-wise assignment: a 22-element inline array literal is stack-too-deep without via-ir.
        (sels[0], names[0]) = (ICounterfactualBeacon.signer.selector, "signer");
        (sels[1], names[1]) = (ICounterfactualBeacon.spokePool.selector, "spokePool");
        (sels[2], names[2]) = (ICounterfactualBeacon.wrappedNativeToken.selector, "wrappedNativeToken");
        (sels[3], names[3]) = (ICounterfactualBeacon.nativeToken.selector, "nativeToken");
        (sels[4], names[4]) = (ICounterfactualBeacon.cctpSrcPeriphery.selector, "cctpSrcPeriphery");
        (sels[5], names[5]) = (ICounterfactualBeacon.cctpTokenMessenger.selector, "cctpTokenMessenger");
        (sels[6], names[6]) = (ICounterfactualBeacon.cctpSourceDomain.selector, "cctpSourceDomain");
        (sels[7], names[7]) = (ICounterfactualBeacon.oftSrcPeriphery.selector, "oftSrcPeriphery");
        (sels[8], names[8]) = (ICounterfactualBeacon.oftSrcEid.selector, "oftSrcEid");
        (sels[9], names[9]) = (ICounterfactualBeacon.usdc.selector, "usdc");
        (sels[10], names[10]) = (ICounterfactualBeacon.usdce.selector, "usdce");
        (sels[11], names[11]) = (ICounterfactualBeacon.usdt.selector, "usdt");
        (sels[12], names[12]) = (ICounterfactualBeacon.wbtc.selector, "wbtc");
        (sels[13], names[13]) = (ICounterfactualBeacon.weth.selector, "weth");
        (sels[14], names[14]) = (ICounterfactualBeacon.usdcCctpMaxExecutionFee.selector, "usdcCctpMaxExecutionFee");
        (sels[15], names[15]) = (ICounterfactualBeacon.usdcCctpMaxFeeBps.selector, "usdcCctpMaxFeeBps");
        (sels[16], names[16]) = (ICounterfactualBeacon.usdtOftMaxExecutionFee.selector, "usdtOftMaxExecutionFee");
        (sels[17], names[17]) = (
            ICounterfactualBeacon.usdcSpokePoolMaxExecutionFee.selector,
            "usdcSpokePoolMaxExecutionFee"
        );
        (sels[18], names[18]) = (
            ICounterfactualBeacon.usdceSpokePoolMaxExecutionFee.selector,
            "usdceSpokePoolMaxExecutionFee"
        );
        (sels[19], names[19]) = (
            ICounterfactualBeacon.usdtSpokePoolMaxExecutionFee.selector,
            "usdtSpokePoolMaxExecutionFee"
        );
        (sels[20], names[20]) = (
            ICounterfactualBeacon.wethSpokePoolMaxExecutionFee.selector,
            "wethSpokePoolMaxExecutionFee"
        );
        (sels[21], names[21]) = (
            ICounterfactualBeacon.wbtcSpokePoolMaxExecutionFee.selector,
            "wbtcSpokePoolMaxExecutionFee"
        );
    }

    // --- ZK-stack degradation ---

    /// @dev On ZK-stack chains, contracts deployed as era-VM bytecode (pre-interpreter SpokePool, tokens)
    ///      cannot execute under the local EVM fork, so a reverted call proves nothing — degrade to REVIEW.
    ///      zkSync Era (324) is family "NONE" in constants.json but physically zk — special-cased.
    function _failOrZkReview(
        uint256 chainId,
        string memory contract_,
        string memory field,
        string memory detail
    ) internal {
        if (chainId == 324 || keccak256(bytes(getChainFamily(chainId))) == keccak256("ZK_STACK")) {
            _reviewNote(
                contract_,
                string.concat(
                    field,
                    ": ",
                    detail,
                    " - era-VM bytecode cannot run under a local EVM fork; verify manually"
                )
            );
        } else {
            _fail(contract_, field, detail);
        }
    }
}
