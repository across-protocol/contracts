// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { ICounterfactualBeacon } from "../../interfaces/ICounterfactualBeacon.sol";
import { CounterfactualBeaconBase } from "./CounterfactualBeaconBase.sol";

/**
 * @notice Chain-specific config baked into a `CounterfactualBeacon` implementation as `public immutable`s,
 *         so leaves read endpoints/tokens/signer from the registry and stay byte-identical across chains.
 *         Each chain deploys its own implementation with its own config.
 */
struct CounterfactualChainConfig {
    address signer;
    address spokePool;
    address wrappedNativeToken;
    /// @dev "Native" SpokePool route: the native sentinel where the deposit is `msg.value` (wrapped to
    ///      `wrappedNativeToken`), or an ERC-20 on chains with no native gas token. See `nativeToken()`.
    address nativeToken;
    address cctpSrcPeriphery;
    address cctpTokenMessenger;
    uint32 cctpSourceDomain;
    /// @dev Single-token OFT periphery (USDT0). The OFT leaf picks the periphery by its getter selector, so
    ///      another OFT token is a beacon upgrade adding another getter.
    address oftSrcPeriphery;
    uint32 oftSrcEid;
    /// @dev Native (Circle-issued or chain-canonical) USDC. Distinct from `usdce` below.
    address usdc;
    /// @dev Bridged USDC.e where it exists as a token distinct from `usdc` — its own input token with its
    ///      own getter/cap, NOT a fallback filling the `usdc` slot. SpokePool routes only (no CCTP burn
    ///      path for bridged USDC).
    address usdce;
    address usdt;
    address wbtc;
    /// @dev Canonical WETH ERC-20 on this chain — an input token like `usdc`/`usdt`/`wbtc`, distinct from
    ///      `wrappedNativeToken` (the wrapped GAS token, e.g. WBNB/WPOL; identical to WETH only on ETH-gas
    ///      chains). Lets leaves route actual WETH on chains whose native asset is not ETH.
    address weth;
    /// @dev Per-(token, bridge) execution-fee caps, in input-token units. A leaf names which to enforce via
    ///      a `bytes4` selector (its `maxExecutionFeeGetter`). Illustrative set — add more as routes need them.
    ///      For SpokePool this is the fixed component of the fee cap (added to the leaf's `maxFeeBps` term).
    uint256 usdcCctpMaxExecutionFee;
    /// @dev Cap on the submitter-chosen Circle fast-transfer fee (vanilla CCTP route), in bps of the
    ///      burned amount (0 ⇒ standard transfers only).
    uint256 usdcCctpMaxFeeBps;
    uint256 usdtOftMaxExecutionFee;
    uint256 usdcSpokePoolMaxExecutionFee;
    uint256 usdceSpokePoolMaxExecutionFee;
    uint256 usdtSpokePoolMaxExecutionFee;
    uint256 wethSpokePoolMaxExecutionFee;
    uint256 wbtcSpokePoolMaxExecutionFee;
    // --- V5 config (see `ICounterfactualBeacon`) -------------------------------------------------------
    /// @dev Across V5 `Gateway` on this chain.
    address gateway;
    /// @dev The USDT0 `IOFT` — V5's OFT bridge endpoint, distinct from `oftSrcPeriphery` (V4's periphery).
    address usdtOft;
    /// @dev V5 executors, resolved by a route leaf's `executorGetter`. `destinationExecutor` is itself
    ///      constructor-bound to the beacon proxy, so it must be deployed against this beacon's proxy
    ///      address (predictable from the CREATE2 salt) before this impl can bake it.
    address spokePoolDepositExecutor;
    address cctpDepositExecutor;
    address oftDepositExecutor;
    address sameChainExecutor;
    address destinationExecutor;
    /// @dev Remaining per-(token, bridge) V5 fee caps, in funded-token units. Zero is a valid value here
    ///      (fee-free route), unlike the V4 caps above.
    uint256 usdtCctpMaxExecutionFee;
    uint256 wethCctpMaxExecutionFee;
    uint256 usdceCctpMaxExecutionFee;
    uint256 usdcOftMaxExecutionFee;
    uint256 wethOftMaxExecutionFee;
    uint256 usdceOftMaxExecutionFee;
    uint256 usdcSameChainMaxExecutionFee;
    uint256 usdtSameChainMaxExecutionFee;
    uint256 wethSameChainMaxExecutionFee;
    uint256 usdceSameChainMaxExecutionFee;
    /// @dev Per-token USD price, 1e18-fixed. Zero marks the token unpriced (volatile), which skips V5's
    ///      stable swap floor for every pair touching it — the normal setting for WETH.
    uint256 usdcStablePrice;
    uint256 usdtStablePrice;
    uint256 wethStablePrice;
    uint256 usdceStablePrice;
}

/**
 * @title CounterfactualBeacon
 * @notice The **configuration** of the per-chain counterfactual registry/beacon: every chain-specific value
 *         (bridge endpoints, domains/EIDs, fee signer, token addresses, fee caps) as a `public immutable`,
 *         named getter. All logic — root/implementation management, UUPS, ownership — lives in
 *         `CounterfactualBeaconBase`. The getter set covers both the V4 counterfactual leaves and the Across
 *         V5 counterfactual vertical (V5 `Gateway`, executors, per-(token, bridge) caps, stable prices),
 *         whose routes resolve them by getter selector — see `ICounterfactualBeacon`.
 * @dev The config is `public immutable` (in code, readable through the proxy under delegatecall), so changing
 *      a value or adding a token/cap means deploying a new implementation and `upgradeToAndCall`-ing to it.
 *      For an identical proxy address across chains, deploy against a uniform bootstrap then upgrade to the
 *      chain-specific implementation.
 *
 *      NOTE: these `immutable` values are **pure configuration**. A new implementation that changes only
 *      them (this contract's constructor wiring, with no change to `CounterfactualBeaconBase`) is a
 *      configuration change and is **not subject to audit** — only changes to the base's *logic* are audited.
 * @custom:security-contact bugs@across.to
 */
contract CounterfactualBeacon is CounterfactualBeaconBase {
    /// @inheritdoc ICounterfactualBeacon
    address public immutable signer;
    /// @inheritdoc ICounterfactualBeacon
    address public immutable spokePool;
    /// @inheritdoc ICounterfactualBeacon
    address public immutable wrappedNativeToken;
    /// @inheritdoc ICounterfactualBeacon
    address public immutable nativeToken;
    /// @inheritdoc ICounterfactualBeacon
    address public immutable cctpSrcPeriphery;
    /// @inheritdoc ICounterfactualBeacon
    address public immutable cctpTokenMessenger;
    /// @inheritdoc ICounterfactualBeacon
    uint32 public immutable cctpSourceDomain;
    /// @inheritdoc ICounterfactualBeacon
    address public immutable oftSrcPeriphery;
    /// @inheritdoc ICounterfactualBeacon
    uint32 public immutable oftSrcEid;
    /// @inheritdoc ICounterfactualBeacon
    address public immutable usdc;
    /// @inheritdoc ICounterfactualBeacon
    address public immutable usdce;
    /// @inheritdoc ICounterfactualBeacon
    address public immutable usdt;
    /// @inheritdoc ICounterfactualBeacon
    address public immutable wbtc;
    /// @inheritdoc ICounterfactualBeacon
    address public immutable weth;
    /// @inheritdoc ICounterfactualBeacon
    uint256 public immutable usdcCctpMaxExecutionFee;
    /// @inheritdoc ICounterfactualBeacon
    uint256 public immutable usdcCctpMaxFeeBps;
    /// @inheritdoc ICounterfactualBeacon
    uint256 public immutable usdtOftMaxExecutionFee;
    /// @inheritdoc ICounterfactualBeacon
    uint256 public immutable usdcSpokePoolMaxExecutionFee;
    /// @inheritdoc ICounterfactualBeacon
    uint256 public immutable usdceSpokePoolMaxExecutionFee;
    /// @inheritdoc ICounterfactualBeacon
    uint256 public immutable usdtSpokePoolMaxExecutionFee;
    /// @inheritdoc ICounterfactualBeacon
    uint256 public immutable wethSpokePoolMaxExecutionFee;
    /// @inheritdoc ICounterfactualBeacon
    uint256 public immutable wbtcSpokePoolMaxExecutionFee;
    /// @inheritdoc ICounterfactualBeacon
    address public immutable gateway;
    /// @inheritdoc ICounterfactualBeacon
    address public immutable usdtOft;
    /// @inheritdoc ICounterfactualBeacon
    address public immutable spokePoolDepositExecutor;
    /// @inheritdoc ICounterfactualBeacon
    address public immutable cctpDepositExecutor;
    /// @inheritdoc ICounterfactualBeacon
    address public immutable oftDepositExecutor;
    /// @inheritdoc ICounterfactualBeacon
    address public immutable sameChainExecutor;
    /// @inheritdoc ICounterfactualBeacon
    address public immutable destinationExecutor;
    /// @inheritdoc ICounterfactualBeacon
    uint256 public immutable usdtCctpMaxExecutionFee;
    /// @inheritdoc ICounterfactualBeacon
    uint256 public immutable wethCctpMaxExecutionFee;
    /// @inheritdoc ICounterfactualBeacon
    uint256 public immutable usdceCctpMaxExecutionFee;
    /// @inheritdoc ICounterfactualBeacon
    uint256 public immutable usdcOftMaxExecutionFee;
    /// @inheritdoc ICounterfactualBeacon
    uint256 public immutable wethOftMaxExecutionFee;
    /// @inheritdoc ICounterfactualBeacon
    uint256 public immutable usdceOftMaxExecutionFee;
    /// @inheritdoc ICounterfactualBeacon
    uint256 public immutable usdcSameChainMaxExecutionFee;
    /// @inheritdoc ICounterfactualBeacon
    uint256 public immutable usdtSameChainMaxExecutionFee;
    /// @inheritdoc ICounterfactualBeacon
    uint256 public immutable wethSameChainMaxExecutionFee;
    /// @inheritdoc ICounterfactualBeacon
    uint256 public immutable usdceSameChainMaxExecutionFee;
    /// @inheritdoc ICounterfactualBeacon
    uint256 public immutable usdcStablePrice;
    /// @inheritdoc ICounterfactualBeacon
    uint256 public immutable usdtStablePrice;
    /// @inheritdoc ICounterfactualBeacon
    uint256 public immutable wethStablePrice;
    /// @inheritdoc ICounterfactualBeacon
    uint256 public immutable usdceStablePrice;

    /// @param config The chain-specific configuration baked into this implementation (see
    ///        `CounterfactualChainConfig`). Each field becomes an immutable, named getter.
    constructor(CounterfactualChainConfig memory config) {
        signer = config.signer;
        spokePool = config.spokePool;
        wrappedNativeToken = config.wrappedNativeToken;
        nativeToken = config.nativeToken;
        cctpSrcPeriphery = config.cctpSrcPeriphery;
        cctpTokenMessenger = config.cctpTokenMessenger;
        cctpSourceDomain = config.cctpSourceDomain;
        oftSrcPeriphery = config.oftSrcPeriphery;
        oftSrcEid = config.oftSrcEid;
        usdc = config.usdc;
        usdce = config.usdce;
        usdt = config.usdt;
        wbtc = config.wbtc;
        weth = config.weth;
        usdcCctpMaxExecutionFee = config.usdcCctpMaxExecutionFee;
        usdcCctpMaxFeeBps = config.usdcCctpMaxFeeBps;
        usdtOftMaxExecutionFee = config.usdtOftMaxExecutionFee;
        usdcSpokePoolMaxExecutionFee = config.usdcSpokePoolMaxExecutionFee;
        usdceSpokePoolMaxExecutionFee = config.usdceSpokePoolMaxExecutionFee;
        usdtSpokePoolMaxExecutionFee = config.usdtSpokePoolMaxExecutionFee;
        wethSpokePoolMaxExecutionFee = config.wethSpokePoolMaxExecutionFee;
        wbtcSpokePoolMaxExecutionFee = config.wbtcSpokePoolMaxExecutionFee;
        gateway = config.gateway;
        usdtOft = config.usdtOft;
        spokePoolDepositExecutor = config.spokePoolDepositExecutor;
        cctpDepositExecutor = config.cctpDepositExecutor;
        oftDepositExecutor = config.oftDepositExecutor;
        sameChainExecutor = config.sameChainExecutor;
        destinationExecutor = config.destinationExecutor;
        usdtCctpMaxExecutionFee = config.usdtCctpMaxExecutionFee;
        wethCctpMaxExecutionFee = config.wethCctpMaxExecutionFee;
        usdceCctpMaxExecutionFee = config.usdceCctpMaxExecutionFee;
        usdcOftMaxExecutionFee = config.usdcOftMaxExecutionFee;
        wethOftMaxExecutionFee = config.wethOftMaxExecutionFee;
        usdceOftMaxExecutionFee = config.usdceOftMaxExecutionFee;
        usdcSameChainMaxExecutionFee = config.usdcSameChainMaxExecutionFee;
        usdtSameChainMaxExecutionFee = config.usdtSameChainMaxExecutionFee;
        wethSameChainMaxExecutionFee = config.wethSameChainMaxExecutionFee;
        usdceSameChainMaxExecutionFee = config.usdceSameChainMaxExecutionFee;
        usdcStablePrice = config.usdcStablePrice;
        usdtStablePrice = config.usdtStablePrice;
        wethStablePrice = config.wethStablePrice;
        usdceStablePrice = config.usdceStablePrice;
        _disableInitializers();
    }

    /// @inheritdoc ICounterfactualBeacon
    /// @dev Dispatches over the configured token addresses; the only logic in this otherwise
    ///      configuration-only contract, and pure config reads (mirrors V5's `MockBeacon.stablePrice`).
    ///      An unconfigured token slot is `address(0)`, which returns 0 before any comparison can alias it.
    function stablePrice(address token) external view returns (uint256) {
        if (token == address(0)) return 0;
        if (token == usdc) return usdcStablePrice;
        if (token == usdt) return usdtStablePrice;
        if (token == weth) return wethStablePrice;
        if (token == usdce) return usdceStablePrice;
        return 0;
    }
}
