// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { DeploymentUtils } from "../utils/DeploymentUtils.sol";
import { Variable, TypeKind } from "forge-std/LibVariable.sol";
import { CounterfactualChainConfig } from "../../contracts/periphery/counterfactual/CounterfactualBeacon.sol";

/// @notice Shared config loader/resolver for counterfactual deploy scripts: operational params from
/// config.toml, chain-specific values from Constants and DeployedAddresses.
abstract contract CounterfactualConfig is DeploymentUtils {
    string constant CONFIG_PATH = "./script/counterfactual/config.toml";

    struct OperationalConfig {
        address signer;
        address ownerAndDirectWithdrawer;
    }

    function _loadCounterfactualConfig() internal {
        _loadConfig(CONFIG_PATH, false);
    }

    function _loadOperationalConfig() internal returns (OperationalConfig memory cfg) {
        _loadCounterfactualConfig();
        cfg.signer = config.get("signer").toAddress();
        require(cfg.signer != address(0), "config: signer is zero");
        cfg.ownerAndDirectWithdrawer = config.get("ownerAndDirectWithdrawer").toAddress();
        require(
            cfg.ownerAndDirectWithdrawer != address(0),
            "config: ownerAndDirectWithdrawer is zero or missing for chain"
        );
    }

    /// @dev Optional per-(token, bridge) execution-fee cap from config.toml for the current chain; 0 if the
    ///      key is absent. These are operational economic params (input-token units), tuned per chain.
    function _resolveFeeCap(string memory key) internal view returns (uint256) {
        Variable memory v = config.get(key);
        return v.ty.kind == TypeKind.Uint256 ? v.toUint256() : 0;
    }

    /// @dev Reads the signer address from config.toml.
    function _loadSigner() internal returns (address) {
        _loadCounterfactualConfig();
        address s = config.get("signer").toAddress();
        require(s != address(0), "config: signer is zero");
        return s;
    }

    function _resolveSpokePool() internal view returns (address) {
        return getDeployedAddress("SpokePool", block.chainid, false);
    }

    function _resolveWrappedNativeToken() internal view returns (address) {
        if (vm.keyExists(file, string.concat(".WRAPPED_NATIVE_TOKENS.", vm.toString(block.chainid)))) {
            return getWrappedNativeToken(block.chainid);
        }
        return address(0);
    }

    /// @dev Standard Aave/Compound-style native sentinel, returned by `beacon.nativeToken()` on chains whose
    ///      "native or equivalent" SpokePool route is paid in `msg.value` (input token is then
    ///      `beacon.wrappedNativeToken()`). Mirrors `CounterfactualDepositSpokePool.NATIVE_SENTINEL`.
    address internal constant NATIVE_SENTINEL = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    /// @dev Resolves the "native or equivalent" SpokePool input token. Defaults to `NATIVE_SENTINEL` (every
    ///      chain with a wrapped native token supports the msg.value-wrap path); a `.NATIVE_TOKEN.<chainId>`
    ///      override in constants.json forces an ERC-20 instead, bypassing the msg.value path. Without a
    ///      `.WRAPPED_NATIVE_TOKENS.<chainId>` entry the sentinel would brick at execution (wrapped native 0 →
    ///      `RouteNotConfigured`), so we fall back to `address(0)` so the leaf cleanly RouteNotConfigured's.
    function _resolveNativeToken() internal view returns (address) {
        string memory path = string.concat(".NATIVE_TOKEN.", vm.toString(block.chainid));
        if (vm.keyExists(file, path)) return vm.parseJsonAddress(file, path);
        if (_resolveWrappedNativeToken() == address(0)) return address(0);
        return NATIVE_SENTINEL;
    }

    /// @dev Tries both casings to handle inconsistency in deployed-addresses.json.
    function _resolveCctpPeriphery() internal view returns (address) {
        address addr = getDeployedAddress("SponsoredCCTPSrcPeriphery", block.chainid, false);
        if (addr == address(0)) addr = getDeployedAddress("SponsoredCctpSrcPeriphery", block.chainid, false);
        return addr;
    }

    function _resolveOftPeriphery() internal view returns (address) {
        return getDeployedAddress("SponsoredOFTSrcPeriphery", block.chainid, false);
    }

    /// @dev Resolves the Circle CCTP v2 TokenMessenger from constants.json: `.L2_ADDRESS_MAP.<chainId>` for
    ///      L2s, `.L1_ADDRESS_MAP.<chainId>` for L1. address(0) when absent (no vanilla CCTP route).
    function _resolveCctpTokenMessenger() internal view returns (address) {
        string memory chainIdStr = vm.toString(block.chainid);
        string memory l2Path = string.concat(".L2_ADDRESS_MAP.", chainIdStr, ".cctpV2TokenMessenger");
        if (vm.keyExists(file, l2Path)) return vm.parseJsonAddress(file, l2Path);
        string memory l1Path = string.concat(".L1_ADDRESS_MAP.", chainIdStr, ".cctpV2TokenMessenger");
        if (vm.keyExists(file, l1Path)) return vm.parseJsonAddress(file, l1Path);
        return address(0);
    }

    /// @dev Resolves USDC for this chain from constants.json (`.USDC.<chainId>`); address(0) if absent.
    function _resolveUsdc() internal view returns (address) {
        if (vm.keyExists(file, string.concat(".USDC.", vm.toString(block.chainid)))) {
            return getUSDCAddress(block.chainid);
        }
        return address(0);
    }

    /// @dev Resolves USDT from constants.json (`.USDT.<chainId>`); address(0) if absent. Mainly needed for
    ///      Tron (`CounterfactualDepositSpokePoolTr` reads `beacon.usdt()`); 0 elsewhere is fine. Without a
    ///      Tron `.USDT.<chainId>` entry the Tron beacon would bake `usdt = 0` and brick every Tron SpokePool
    ///      route with `RouteNotConfigured`, so `_buildChainConfig` rejects it below.
    function _resolveUsdt() internal view returns (address) {
        string memory path = string.concat(".USDT.", vm.toString(block.chainid));
        if (vm.keyExists(file, path)) return vm.parseJsonAddress(file, path);
        return address(0);
    }

    /// @notice Builds the per-chain `CounterfactualChainConfig` baked into the chain-specific
    ///         `CounterfactualBeacon` impl. Missing values resolve to 0 (route simply not configured).
    ///         `_loadCounterfactualConfig()` must run first — it does, via `_loadSigner` below.
    function _buildChainConfig() internal returns (CounterfactualChainConfig memory cfg) {
        cfg.signer = _loadSigner();
        cfg.spokePool = _resolveSpokePool();
        cfg.wrappedNativeToken = _resolveWrappedNativeToken();
        cfg.nativeToken = _resolveNativeToken();
        cfg.cctpSrcPeriphery = _resolveCctpPeriphery();
        cfg.cctpSourceDomain = hasCctpDomain(block.chainid) ? getCircleDomainId(block.chainid) : 0;
        cfg.cctpTokenMessenger = _resolveCctpTokenMessenger();
        cfg.oftSrcPeriphery = _resolveOftPeriphery();
        cfg.oftSrcEid = hasOftEid(block.chainid) ? uint32(getOftEid(block.chainid)) : 0;
        cfg.usdc = _resolveUsdc();
        cfg.usdt = _resolveUsdt();
        // Per-(token, bridge) execution-fee caps from config.toml (operational; 0 if unset). A leaf names
        // which cap to enforce via its `maxExecutionFeeGetter` selector.
        cfg.usdcCctpMaxExecutionFee = _resolveFeeCap("usdcCctpMaxExecutionFee");
        // Bps cap (not token units) on the submitter-chosen Circle fast-transfer fee (vanilla CCTP);
        // 0 if unset ⇒ standard transfers only on this chain.
        cfg.usdcCctpMaxFeeBps = _resolveFeeCap("usdcCctpMaxFeeBps");
        cfg.usdtOftMaxExecutionFee = _resolveFeeCap("usdtOftMaxExecutionFee");
        cfg.usdcSpokePoolMaxExecutionFee = _resolveFeeCap("usdcSpokePoolMaxExecutionFee");
        cfg.usdtSpokePoolMaxExecutionFee = _resolveFeeCap("usdtSpokePoolMaxExecutionFee");
        cfg.wethSpokePoolMaxExecutionFee = _resolveFeeCap("wethSpokePoolMaxExecutionFee");
        // SpokePool is the foundational route. Baking `spokePool = 0` silently bricks every SpokePool leaf,
        // fixable only by a registry UUPS upgrade (the value is immutable on the impl). Refuse to deploy
        // without a SpokePool entry.
        require(
            cfg.spokePool != address(0),
            "config: SpokePool must be deployed on this chain (add to deployed-addresses.json)"
        );
        // Tron's `CounterfactualDepositSpokePoolTr` is USDT-only; baking `usdt = 0` bricks every Tron
        // SpokePool route. Require an explicit `.USDT.728126428` entry in constants.json before deploying.
        require(
            block.chainid != 728126428 || cfg.usdt != address(0),
            "config: USDT must be configured for Tron (add .USDT.728126428 to constants.json)"
        );
        // The sentinel means "wrap msg.value into `wrappedNativeToken`", so it's meaningless without one.
        // `_resolveNativeToken` upholds this for the default path but returns a `.NATIVE_TOKEN.<chainId>`
        // override verbatim, so guard the pairing here rather than baking a sentinel that bricks at execution.
        require(
            cfg.nativeToken != NATIVE_SENTINEL || cfg.wrappedNativeToken != address(0),
            "config: nativeToken=sentinel requires wrappedNativeToken"
        );
    }
}
