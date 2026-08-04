// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { console } from "forge-std/console.sol";
import { Variable, TypeKind } from "forge-std/LibVariable.sol";
import { CounterfactualConfig } from "../CounterfactualConfig.sol";
import { CounterfactualChainConfig } from "../../../contracts/periphery/counterfactual/CounterfactualBeacon.sol";

/// @notice Config loader for the V5 TEST beacons. Reuses every resolver in `CounterfactualConfig` but reads
///         `v5-test-beacons/config.toml` instead of the production file, lets any resolved address be
///         overridden by a same-named key there, and supplies the V5-only values (`gateway`, the executors,
///         `usdtOft`, the per-(token, bridge) caps, the stable prices) that no resolver can produce.
/// @dev    Every config key is named after the beacon getter it feeds — V5 routes commit getter selectors, so
///         the name is the wire format. Two rules differ from production on purpose, because the V5 surface is
///         still moving: there is no `[N.bool]` declared-support cross-check, and a missing/zero value is
///         permitted (and logged) rather than fatal. See the config.toml header for what each zero means.
abstract contract V5TestBeaconConfig is CounterfactualConfig {
    string internal constant V5_TEST_CONFIG_PATH = "./script/counterfactual/v5-test-beacons/config.toml";

    /// @dev Per-run CREATE2 salt override; `bytes32(0)` means "use the config value" (see `_deploySalt`).
    bytes32 private saltOverride;

    /// @inheritdoc CounterfactualConfig
    function _configPath() internal pure override returns (string memory) {
        return V5_TEST_CONFIG_PATH;
    }

    /// @inheritdoc CounterfactualConfig
    /// @dev A non-zero `_overrideSalt` wins over `[0.bytes32] deploySalt`, so a one-off deploy can be sent to
    ///      a fresh set of addresses without editing the file. `bytes32(0)` is not treated as an override —
    ///      it is also what an unset config value reads as, so the two collapse to the same meaning.
    function _deploySalt() internal override returns (bytes32) {
        return saltOverride != bytes32(0) ? saltOverride : super._deploySalt();
    }

    /// @dev Records the CLI salt argument. Must be called before any address prediction.
    function _overrideSalt(bytes32 salt) internal {
        saltOverride = salt;
    }

    /// @notice The per-chain config baked into a V5 test `CounterfactualBeacon` implementation.
    /// @dev V4 fields keep their resolvers with an override layered on top; V5 fields come from config.toml
    ///      alone. Overrides are logged individually so a review of the run output is a review of the diff
    ///      against constants.json / deployed-addresses.json.
    function _buildV5TestChainConfig() internal returns (CounterfactualChainConfig memory cfg) {
        _requireChainConfigured(); // before any read, so an unconfigured chain says so instead of "signer is zero"
        cfg.signer = _loadSigner(); // reverts if zero: every V5 flow needs the quote signer

        // --- V4 substrate: resolved, overridable ---------------------------------------------------------
        cfg.spokePool = _addressOr("spokePool", _resolveSpokePool());
        cfg.wrappedNativeToken = _addressOr("wrappedNativeToken", _resolveWrappedNativeToken());
        cfg.nativeToken = _addressOr("nativeToken", _resolveNativeToken());
        cfg.cctpSrcPeriphery = _addressOr("cctpSrcPeriphery", _resolveCctpPeriphery());
        cfg.cctpTokenMessenger = _addressOr("cctpTokenMessenger", _resolveCctpTokenMessenger());
        cfg.cctpSourceDomain = uint32(
            _uintOr("cctpSourceDomain", hasCctpDomain(block.chainid) ? getCircleDomainId(block.chainid) : 0)
        );
        cfg.oftSrcPeriphery = _addressOr("oftSrcPeriphery", _resolveOftPeriphery());
        cfg.oftSrcEid = uint32(_uintOr("oftSrcEid", hasOftEid(block.chainid) ? getOftEid(block.chainid) : 0));
        cfg.usdc = _addressOr("usdc", _resolveUsdc());
        cfg.usdce = _addressOr("usdce", _resolveUsdce(cfg.usdc));
        cfg.usdt = _addressOr("usdt", _resolveUsdt());
        cfg.wbtc = _addressOr("wbtc", _resolveWbtc());
        cfg.weth = _addressOr("weth", _resolveWeth());

        // --- V5 endpoints and executors: config.toml only ------------------------------------------------
        cfg.gateway = _address("gateway");
        cfg.usdtOft = _address("usdtOft");
        cfg.spokePoolDepositExecutor = _address("spokePoolDepositExecutor");
        cfg.cctpDepositExecutor = _address("cctpDepositExecutor");
        cfg.oftDepositExecutor = _address("oftDepositExecutor");
        cfg.sameChainExecutor = _address("sameChainExecutor");
        cfg.destinationExecutor = _address("destinationExecutor");

        // --- Fee caps, keyed by the getter they feed. Zero is a valid value here (fee-free route), so these
        //     are read permissively rather than through the production `_maxExecutionFee` assertions.
        cfg.usdcSpokePoolMaxExecutionFee = _uint("usdcSpokePoolMaxExecutionFee");
        cfg.usdtSpokePoolMaxExecutionFee = _uint("usdtSpokePoolMaxExecutionFee");
        cfg.wethSpokePoolMaxExecutionFee = _uint("wethSpokePoolMaxExecutionFee");
        cfg.usdceSpokePoolMaxExecutionFee = _uint("usdceSpokePoolMaxExecutionFee");
        cfg.wbtcSpokePoolMaxExecutionFee = _uint("wbtcSpokePoolMaxExecutionFee");
        cfg.usdcCctpMaxExecutionFee = _uint("usdcCctpMaxExecutionFee");
        cfg.usdtCctpMaxExecutionFee = _uint("usdtCctpMaxExecutionFee");
        cfg.wethCctpMaxExecutionFee = _uint("wethCctpMaxExecutionFee");
        cfg.usdceCctpMaxExecutionFee = _uint("usdceCctpMaxExecutionFee");
        cfg.usdcOftMaxExecutionFee = _uint("usdcOftMaxExecutionFee");
        cfg.usdtOftMaxExecutionFee = _uint("usdtOftMaxExecutionFee");
        cfg.wethOftMaxExecutionFee = _uint("wethOftMaxExecutionFee");
        cfg.usdceOftMaxExecutionFee = _uint("usdceOftMaxExecutionFee");
        cfg.usdcSameChainMaxExecutionFee = _uint("usdcSameChainMaxExecutionFee");
        cfg.usdtSameChainMaxExecutionFee = _uint("usdtSameChainMaxExecutionFee");
        cfg.wethSameChainMaxExecutionFee = _uint("wethSameChainMaxExecutionFee");
        cfg.usdceSameChainMaxExecutionFee = _uint("usdceSameChainMaxExecutionFee");
        cfg.usdcCctpMaxFeeBps = _uint("usdcCctpMaxFeeBps");

        // --- Stable prices. Zero = unpriced (volatile), which SKIPS V5's stable floor for every pair
        //     touching the token; that is the intended setting for WETH, not an omission.
        cfg.usdcStablePrice = _uint("usdcStablePrice");
        cfg.usdtStablePrice = _uint("usdtStablePrice");
        cfg.wethStablePrice = _uint("wethStablePrice");
        cfg.usdceStablePrice = _uint("usdceStablePrice");

        // The SpokePool route is the foundational one and the value is immutable once baked, so refuse to
        // deploy an impl that would brick every SpokePool leaf. Mirrors the production builder.
        require(cfg.spokePool != address(0), "config: spokePool is zero (set the V5 SpokePool for this chain)");
        // The sentinel means "wrap msg.value into `wrappedNativeToken`", so it is meaningless without one.
        require(
            cfg.nativeToken != NATIVE_SENTINEL || cfg.wrappedNativeToken != address(0),
            "config: nativeToken=sentinel requires wrappedNativeToken"
        );
        _logChainConfig(cfg);
    }

    // --- Readers -----------------------------------------------------------------------------------------

    /// @dev The `[N.address]` value for `getter` if present, else the resolver's `resolved` value. Logs the
    ///      substitution so every divergence from constants.json / deployed-addresses.json is visible.
    function _addressOr(string memory getter, address resolved) private returns (address) {
        Variable memory v = _value(getter);
        if (v.ty.kind != TypeKind.Address) return resolved;
        address configured = v.toAddress();
        if (configured != resolved) console.log("  override %s: %s (resolved: %s)", getter, configured, resolved);
        return configured;
    }

    /// @dev A V5-only address getter: config.toml or `address(0)` (route not configured, fails closed).
    function _address(string memory getter) private returns (address) {
        Variable memory v = _value(getter);
        if (v.ty.kind == TypeKind.Address) return v.toAddress();
        console.log("  unset %s -> address(0): routes resolving it will revert RouteNotConfigured", getter);
        return address(0);
    }

    /// @dev A uint getter: config.toml or 0. Zero is a valid configured value for every uint on this beacon
    ///      (fee-free route / unpriced token), so an absent key is not logged as loudly as an absent address.
    function _uint(string memory getter) private returns (uint256) {
        return _uintOr(getter, 0);
    }

    function _uintOr(string memory getter, uint256 fallbackValue) private returns (uint256) {
        Variable memory v = _value(getter);
        return v.ty.kind == TypeKind.Uint256 ? v.toUint256() : fallbackValue;
    }

    /// @dev `StdConfig.get` returns `TypeKind.None` (not a revert) for a key the active chain lacks, which is
    ///      how "absent ⇒ default" is detected throughout this file.
    function _value(string memory getter) private returns (Variable memory) {
        _loadCounterfactualConfig();
        return config.get(getter);
    }

    /// @dev `StdConfig.get` also returns `None` for every key of a chain that has NO section at all, which
    ///      would silently bake an all-zero beacon. Fail loudly instead.
    function _requireChainConfigured() private {
        _loadCounterfactualConfig();
        uint256[] memory ids = config.getChainIds();
        for (uint256 i = 0; i < ids.length; i++) {
            if (ids[i] == block.chainid) return;
        }
        revert("v5-test-beacons/config.toml: no section for this chain (Base and Arbitrum are configured)");
    }

    // --- Logging -----------------------------------------------------------------------------------------

    /// @dev Prints everything about to be baked as immutables. These values can only be changed by deploying
    ///      a new impl and UUPS-upgrading the proxy, so the run output is the last chance to catch a typo.
    function _logChainConfig(CounterfactualChainConfig memory cfg) private view {
        console.log("--- V5 test beacon config (chain %d) ---", block.chainid);
        console.log("  signer:              ", cfg.signer);
        console.log("  spokePool (V5):      ", cfg.spokePool);
        console.log("  gateway:             ", cfg.gateway);
        console.log("  wrappedNativeToken:  ", cfg.wrappedNativeToken);
        console.log("  nativeToken:         ", cfg.nativeToken);
        console.log("  usdc / usdce:        ", cfg.usdc, cfg.usdce);
        console.log("  usdt / weth:         ", cfg.usdt, cfg.weth);
        console.log("  wbtc:                ", cfg.wbtc);
        console.log("  cctpTokenMessenger:  ", cfg.cctpTokenMessenger);
        console.log("  cctpSrcPeriphery:    ", cfg.cctpSrcPeriphery);
        console.log("  oftSrcPeriphery:     ", cfg.oftSrcPeriphery);
        console.log("  usdtOft:             ", cfg.usdtOft);
        console.log("  cctpSourceDomain / oftSrcEid: %d / %d", cfg.cctpSourceDomain, cfg.oftSrcEid);
        console.log("  spokePoolDepositExecutor:", cfg.spokePoolDepositExecutor);
        console.log("  cctpDepositExecutor:     ", cfg.cctpDepositExecutor);
        console.log("  oftDepositExecutor:      ", cfg.oftDepositExecutor);
        console.log("  sameChainExecutor:       ", cfg.sameChainExecutor);
        console.log("  destinationExecutor:     ", cfg.destinationExecutor);
        console.log("  usdcCctpMaxFeeBps:        %d", cfg.usdcCctpMaxFeeBps);
        console.log("  stablePrice usdc/usdt:    %d / %d", cfg.usdcStablePrice, cfg.usdtStablePrice);
        console.log("  stablePrice weth/usdce:   %d / %d", cfg.wethStablePrice, cfg.usdceStablePrice);
        console.log("---------------------------------------");
    }
}
