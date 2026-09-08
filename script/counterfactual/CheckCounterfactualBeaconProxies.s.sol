// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { console } from "forge-std/console.sol";
import { Variable, TypeKind } from "forge-std/LibVariable.sol";
import { CounterfactualConfig } from "./CounterfactualConfig.sol";
import { CheckUtils } from "./CheckUtils.sol";
import { ChainConfigResolver } from "./CheckCounterfactualBeaconImpls.s.sol";
import { CounterfactualChainConfig } from "../../contracts/periphery/counterfactual/CounterfactualBeacon.sol";
import { ICounterfactualBeacon } from "../../contracts/interfaces/ICounterfactualBeacon.sol";

// Verifies the LIVE CounterfactualBeacon proxy on every config.toml chain — every read goes through the
// proxy (i.e. reflects whatever impl is live right now), never a bare implementation. Complements:
//   - CheckCounterfactualBeaconImpls.s.sol: freshly deployed impls BEFORE the proxy points at them
//   - CheckCounterfactualDeployments.s.sol: the broader deployment surface (leaf impls, peripheries)
//
// Per chain:
//   - Every beacon config getter (through the proxy) vs a fresh `_buildChainConfig()` — the exact
//     resolver impl deploys bake from (constants.json + deployed-addresses.json + config.toml). A
//     mismatch means the LIVE beacon lags current intent: deploy + upgrade to a fresh impl.
//     Exception: `usdcCctpMaxFeeBps` is skipped on chains without a USDC CCTP burn path (no USDC, or no
//     CCTP messenger/periphery) — the cap only gates USDC CCTP burns, so a stale value is inert there.
//   - Ownership: the proxy's `owner()` (+ any nonzero `pendingOwner()`, reported for visibility) and the
//     AdminWithdrawManager's `owner()`/`directWithdrawer()` vs this chain's config.toml
//     `ownerAndDirectWithdrawer`. Mismatches are REVIEW, not FAIL — dev-wallet custody is a known
//     migration state.
//
// Tron is skipped (forge cannot fork Tron). On ZK-stack chains, reads that fail under the local EVM
// degrade to [REVIEW] instead of [FAIL] (era-VM bytecode; see CheckUtils).
//
// Output prefixes for easy grep: [PASS] / [FAIL] / [REVIEW] / [INFO] (see CheckUtils).
//
// How to run (--gas-limit: one EVM frame spans ~24 forks of JSON-cheatcode work, which outgrows the
// default gas limit):
//   source .env
//   FOUNDRY_PROFILE=counterfactual forge script \
//     script/counterfactual/CheckCounterfactualBeaconProxies.s.sol:CheckCounterfactualBeaconProxies \
//     --rpc-url $NODE_URL_1 --ffi --gas-limit 100000000000 -vv
contract CheckCounterfactualBeaconProxies is CounterfactualConfig, CheckUtils {
    uint256 constant TRON_CHAIN_ID = 728126428;

    ChainConfigResolver resolver;

    function run() external {
        _loadCounterfactualConfig();
        _loadDeployedAddresses();

        // One resolver for the whole run, persistent across forks (see CheckCounterfactualBeaconImpls:
        // constructing per fork re-reads the multi-MB constants.json, which does not fit in the CREATE
        // frame on low-block-gas-limit chains; deployCode keeps its creation code out of this contract).
        resolver = ChainConfigResolver(deployCode("CheckCounterfactualBeaconImpls.s.sol:ChainConfigResolver"));
        vm.makePersistent(address(resolver));

        uint256[] memory chains = config.getChainIds();
        for (uint256 i = 0; i < chains.length; i++) {
            uint256 chainId = chains[i];
            // Skip the synthetic `[0]` globals section in config.toml (holds the deploy salt, not a real chain).
            if (chainId == GLOBALS_CHAIN_ID) continue;
            if (chainId == TRON_CHAIN_ID) {
                _info("Tron", "skipped: forge cannot fork Tron");
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
        console.log("");
        console.log("## %s (Chain %s)", _getChainName(chainId), chainId);

        address proxy = _getDeployed("CounterfactualBeacon", chainId);
        if (proxy == address(0)) {
            _fail("BeaconProxy", "address", "not in deployed-addresses.json");
            return;
        }
        if (proxy.code.length == 0) {
            _fail("BeaconProxy", "bytecode", string.concat("no code on-chain: ", vm.toString(proxy)));
            return;
        }
        _info("BeaconProxy", string.concat("checking live proxy ", vm.toString(proxy)));

        // Probe before comparing: if reads through the proxy cannot execute under the local EVM (e.g.
        // era-VM bytecode), degrade instead of hard-failing 22 getters.
        (bool readable, ) = _tryReadWord(proxy, abi.encodeCall(ICounterfactualBeacon.signer, ()));
        if (!readable) {
            _failOrZkReview(chainId, "BeaconProxy", "getters", "unreadable under the local EVM");
        } else {
            // Re-resolve this chain's expected config with the deploy scripts' own resolver and diff every
            // getter. A resolution revert (flag mismatch, missing fee cap...) means the sources moved out
            // from under the live beacon — a FAIL either way.
            try resolver.build() returns (CounterfactualChainConfig memory expected) {
                _compareConfig(chainId, proxy, expected);
            } catch Error(string memory reason) {
                _fail("BeaconProxy", "expectedConfig", reason);
            } catch {
                _fail("BeaconProxy", "expectedConfig", "config resolution reverted (revert strings stripped?)");
            }
        }

        _checkOwnership(chainId, proxy);
    }

    // --- Getter-by-getter compare vs the deploy-time resolver (all reads THROUGH the proxy) ---

    /// @dev Low-level reads so a proxy running an impl of any vintage can be checked — a live impl
    ///      predating a getter (e.g. pre-usdce) reports "[FAIL] getter missing" instead of reverting.
    function _compareConfig(uint256 chainId, address proxy, CounterfactualChainConfig memory e) internal {
        (bytes4[22] memory sels, string[22] memory names) = _configGetters();
        bytes32[22] memory expected = _expectedWords(e);
        // usdcCctpMaxFeeBps only gates USDC CCTP burns; without a USDC CCTP burn path (no USDC, or no
        // messenger/periphery — e.g. BSC has USDC but no CCTP) the live value is inert, so a stale cap
        // alone shouldn't fail an otherwise-current beacon.
        bool noCctpBurnPath = e.usdc == address(0) ||
            (e.cctpSrcPeriphery == address(0) && e.cctpTokenMessenger == address(0));
        for (uint256 i = 0; i < sels.length; i++) {
            if (sels[i] == ICounterfactualBeacon.usdcCctpMaxFeeBps.selector && noCctpBurnPath) {
                _info("BeaconProxy", string.concat(names[i], " skipped (no USDC CCTP burn path; value is inert)"));
                continue;
            }
            (bool ok, bytes32 actual) = _tryReadWord(proxy, abi.encodeWithSelector(sels[i]));
            if (!ok) {
                _failOrZkReview(chainId, "BeaconProxy", names[i], "getter missing/unreadable on the live impl");
            } else if (actual != expected[i]) {
                console.log("[FAIL]   BeaconProxy.%s", names[i]);
                console.log("           live:     %s", vm.toString(actual));
                console.log("           expected: %s", vm.toString(expected[i]));
                totalFail++;
            } else {
                _pass("BeaconProxy", names[i], vm.toString(actual));
            }
        }
    }

    // --- Ownership: beacon proxy owner + AdminWithdrawManager owner/directWithdrawer ---

    /// @dev The beacon owner can UUPS-upgrade the registry (retargeting every counterfactual proxy) and
    ///      the AdminWithdrawManager roles move user-recoverable funds, so both must end up on this
    ///      chain's config.toml `ownerAndDirectWithdrawer`. Mismatches are REVIEW, not FAIL —
    ///      dev-wallet custody is a known migration state.
    function _checkOwnership(uint256 chainId, address proxy) internal {
        Variable memory v = config.get(chainId, "ownerAndDirectWithdrawer");
        if (v.ty.kind != TypeKind.Address) {
            _reviewNote("Ownership", "config.toml has no ownerAndDirectWithdrawer for this chain - checks skipped");
            return;
        }
        address expected = v.toAddress();

        _checkOwnedRole(chainId, "BeaconProxy", "owner()", proxy, expected);
        // A nonzero pendingOwner is an in-flight Ownable2Step transfer: surface it (acceptOwnership
        // pending), but stay quiet when zero — that is the steady state.
        (bool ok, bytes32 w) = _tryReadWord(proxy, abi.encodeWithSignature("pendingOwner()"));
        if (ok && _toAddr(w) != address(0)) {
            _reviewNote(
                "BeaconProxy",
                string.concat("pendingOwner() = ", vm.toString(_toAddr(w)), " - awaiting acceptOwnership()")
            );
        }

        address awm = _getDeployed("AdminWithdrawManager", chainId);
        if (awm == address(0) || awm.code.length == 0) {
            _info("AdminWithdrawManager", "not deployed on this chain - ownership checks skipped");
            return;
        }
        _checkOwnedRole(chainId, "AdminWithdrawManager", "owner()", awm, expected);
        _checkOwnedRole(chainId, "AdminWithdrawManager", "directWithdrawer()", awm, expected);
    }

    function _checkOwnedRole(
        uint256 chainId,
        string memory contract_,
        string memory sig,
        address target,
        address expected
    ) internal {
        (bool ok, bytes32 w) = _tryReadWord(target, abi.encodeWithSignature(sig));
        if (!ok) {
            _failOrZkReview(chainId, contract_, sig, "unreadable under the local EVM");
            return;
        }
        address actual = _toAddr(w);
        if (actual == expected) {
            _pass(contract_, sig, string.concat(vm.toString(actual), " (= ownerAndDirectWithdrawer)"));
        } else {
            _reviewNote(
                contract_,
                string.concat(
                    sig,
                    " = ",
                    vm.toString(actual),
                    " (config.toml ownerAndDirectWithdrawer: ",
                    vm.toString(expected),
                    ")"
                )
            );
        }
    }

    // --- Getter table (keep in sync with CheckCounterfactualBeaconImpls) ---

    function _toAddr(bytes32 word) internal pure returns (address) {
        return address(uint160(uint256(word)));
    }

    function _addrWord(address a) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(a)));
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

    /// @dev Every config getter on ICounterfactualBeacon (excludes `implementation`/`upgradeRoot`, which
    ///      are proxy-storage reads verified by CheckCounterfactualDeployments).
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

    // --- ZK-stack degradation (mirrors CheckCounterfactualBeaconImpls) ---

    /// @dev On ZK-stack chains, contracts deployed as era-VM bytecode cannot execute under the local EVM
    ///      fork, so a reverted call proves nothing — degrade to REVIEW. zkSync Era (324) is family
    ///      "NONE" in constants.json but physically zk — special-cased.
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
