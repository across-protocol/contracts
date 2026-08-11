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
    // --- Authority --------------------------------------------------------------------------------------
    /// @dev Off-chain signer authorizing runtime execution fees, and the authority of the requirements plan.
    address signer;
    /// @dev The Across V5 `Gateway` on this chain.
    address gateway;
    // --- Tokens -----------------------------------------------------------------------------------------
    // Each is an input token (and a swap output token), named by a leaf's `inputTokenGetter` /
    // `swapOutputTokenGetter`. Every one carries its own fee caps and price below; none is a fallback for
    // another.
    /// @dev Native (Circle-issued or chain-canonical) USDC. Distinct from `usdce`.
    address usdc;
    /// @dev Bridged USDC.e where it exists as a token distinct from `usdc` — its own input token with its
    ///      own getter/cap, NOT a fallback filling the `usdc` slot. No CCTP burn path for bridged USDC.
    address usdce;
    address usdt;
    address wbtc;
    /// @dev Canonical WETH ERC-20 on this chain — an input token like `usdc`/`usdt`/`wbtc`, distinct from
    ///      `wrappedNativeToken` (the wrapped GAS token, e.g. WBNB/WPOL; identical to WETH only on ETH-gas
    ///      chains). Lets leaves route actual WETH on chains whose native asset is not ETH.
    address weth;
    /// @dev pathUSD — Tempo's TIP-20 settlement token, an ordinary ERC-20 input token. Tempo denominates
    ///      gas in it, but there is no wrapped form and no `msg.value` path, so its routes are plain ERC-20
    ///      transfers. A stablecoin, so unlike WETH/WBTC it carries a non-zero `pathUsdStablePrice`.
    address pathUsd;
    /// @dev USDG (Global Dollar), a 6-decimal stablecoin — Robinhood only today. A plain ERC-20 input token,
    ///      priced like the other stablecoins.
    address usdg;
    // --- Bridge endpoints and routing ---------------------------------------------------------------------
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
    /// @dev The USDT0 OFT **messenger** (`IOFT`) — the contract the V5 OFT executor approves and calls
    ///      `send` on, i.e. `SponsoredOFTSrcPeriphery.OFT_MESSENGER`. Not the USDT token, not the LayerZero
    ///      endpoint, and distinct from `oftSrcPeriphery` (V4's periphery). Must satisfy
    ///      `IOFT(usdtOft).token() == usdt` on any chain where it is set — see `ICounterfactualBeacon`.
    address usdtOft;
    // --- Executors ----------------------------------------------------------------------------------------
    /// @dev Resolved by a route leaf's `executorGetter`. Source-side only: the destination executor is
    ///      committed directly by the route (folded into its `dstStepId`) and never resolved here.
    address spokePoolDepositExecutor;
    address cctpDepositExecutor;
    address oftDepositExecutor;
    address sameChainExecutor;
    // --- Execution-fee caps, in input-token units -----------------------------------------------------------
    // A leaf names which to enforce via a `bytes4` selector (its `maxExecutionFeeGetter`). For SpokePool this
    // is the fixed component of the cap (added to the leaf's `maxFeeBps` term). One entry per (token, bridge)
    // pair that can exist: SpokePool and same-chain take any supported token, whereas CCTP burns USDC only
    // and the OFT route is USDT0 only, so those two have a single cap each.
    uint256 usdcSpokePoolMaxExecutionFee;
    uint256 usdceSpokePoolMaxExecutionFee;
    uint256 usdtSpokePoolMaxExecutionFee;
    uint256 wethSpokePoolMaxExecutionFee;
    uint256 wbtcSpokePoolMaxExecutionFee;
    uint256 pathUsdSpokePoolMaxExecutionFee;
    uint256 usdgSpokePoolMaxExecutionFee;
    uint256 usdcSameChainMaxExecutionFee;
    uint256 usdceSameChainMaxExecutionFee;
    uint256 usdtSameChainMaxExecutionFee;
    uint256 wethSameChainMaxExecutionFee;
    uint256 wbtcSameChainMaxExecutionFee;
    uint256 pathUsdSameChainMaxExecutionFee;
    uint256 usdgSameChainMaxExecutionFee;
    uint256 usdcCctpMaxExecutionFee;
    uint256 usdtOftMaxExecutionFee;
    /// @dev Cap on the submitter-chosen Circle fast-transfer fee (vanilla CCTP route), in bps of the
    ///      burned amount (0 ⇒ standard transfers only). Bps, not token units, unlike every cap above.
    uint256 usdcCctpMaxFeeBps;
    // --- Prices -------------------------------------------------------------------------------------------
    /// @dev Per-token USD price, 1e18-fixed. Zero marks the token unpriced, which skips the stable floor for
    ///      every pair touching it — the normal setting for the volatile tokens (WETH, WBTC), which keep a
    ///      slot anyway so the getter set stays complete for the selectors routes commit against.
    uint256 usdcStablePrice;
    uint256 usdceStablePrice;
    uint256 usdtStablePrice;
    uint256 pathUsdStablePrice;
    uint256 usdgStablePrice;
    uint256 wethStablePrice;
    uint256 wbtcStablePrice;
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
    // --- Authority ---
    /// @inheritdoc ICounterfactualBeacon
    address public immutable signer;
    /// @inheritdoc ICounterfactualBeacon
    address public immutable gateway;
    // --- Tokens ---
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
    address public immutable pathUsd;
    /// @inheritdoc ICounterfactualBeacon
    address public immutable usdg;
    // --- Bridge endpoints and routing ---
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
    address public immutable usdtOft;
    // --- Executors ---
    /// @inheritdoc ICounterfactualBeacon
    address public immutable spokePoolDepositExecutor;
    /// @inheritdoc ICounterfactualBeacon
    address public immutable cctpDepositExecutor;
    /// @inheritdoc ICounterfactualBeacon
    address public immutable oftDepositExecutor;
    /// @inheritdoc ICounterfactualBeacon
    address public immutable sameChainExecutor;
    // --- Execution-fee caps ---
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
    uint256 public immutable pathUsdSpokePoolMaxExecutionFee;
    /// @inheritdoc ICounterfactualBeacon
    uint256 public immutable usdgSpokePoolMaxExecutionFee;
    /// @inheritdoc ICounterfactualBeacon
    uint256 public immutable usdcSameChainMaxExecutionFee;
    /// @inheritdoc ICounterfactualBeacon
    uint256 public immutable usdceSameChainMaxExecutionFee;
    /// @inheritdoc ICounterfactualBeacon
    uint256 public immutable usdtSameChainMaxExecutionFee;
    /// @inheritdoc ICounterfactualBeacon
    uint256 public immutable wethSameChainMaxExecutionFee;
    /// @inheritdoc ICounterfactualBeacon
    uint256 public immutable wbtcSameChainMaxExecutionFee;
    /// @inheritdoc ICounterfactualBeacon
    uint256 public immutable pathUsdSameChainMaxExecutionFee;
    /// @inheritdoc ICounterfactualBeacon
    uint256 public immutable usdgSameChainMaxExecutionFee;
    /// @inheritdoc ICounterfactualBeacon
    uint256 public immutable usdcCctpMaxExecutionFee;
    /// @inheritdoc ICounterfactualBeacon
    uint256 public immutable usdtOftMaxExecutionFee;
    /// @inheritdoc ICounterfactualBeacon
    uint256 public immutable usdcCctpMaxFeeBps;
    // --- Prices ---
    /// @inheritdoc ICounterfactualBeacon
    uint256 public immutable usdcStablePrice;
    /// @inheritdoc ICounterfactualBeacon
    uint256 public immutable usdceStablePrice;
    /// @inheritdoc ICounterfactualBeacon
    uint256 public immutable usdtStablePrice;
    /// @inheritdoc ICounterfactualBeacon
    uint256 public immutable pathUsdStablePrice;
    /// @inheritdoc ICounterfactualBeacon
    uint256 public immutable usdgStablePrice;
    /// @inheritdoc ICounterfactualBeacon
    uint256 public immutable wethStablePrice;
    /// @inheritdoc ICounterfactualBeacon
    uint256 public immutable wbtcStablePrice;

    /// @param config The chain-specific configuration baked into this implementation (see
    ///        `CounterfactualChainConfig`). Each field becomes an immutable, named getter.
    constructor(CounterfactualChainConfig memory config) {
        signer = config.signer;
        gateway = config.gateway;
        usdc = config.usdc;
        usdce = config.usdce;
        usdt = config.usdt;
        wbtc = config.wbtc;
        weth = config.weth;
        pathUsd = config.pathUsd;
        usdg = config.usdg;
        spokePool = config.spokePool;
        wrappedNativeToken = config.wrappedNativeToken;
        nativeToken = config.nativeToken;
        cctpSrcPeriphery = config.cctpSrcPeriphery;
        cctpTokenMessenger = config.cctpTokenMessenger;
        cctpSourceDomain = config.cctpSourceDomain;
        oftSrcPeriphery = config.oftSrcPeriphery;
        oftSrcEid = config.oftSrcEid;
        usdtOft = config.usdtOft;
        spokePoolDepositExecutor = config.spokePoolDepositExecutor;
        cctpDepositExecutor = config.cctpDepositExecutor;
        oftDepositExecutor = config.oftDepositExecutor;
        sameChainExecutor = config.sameChainExecutor;
        usdcSpokePoolMaxExecutionFee = config.usdcSpokePoolMaxExecutionFee;
        usdceSpokePoolMaxExecutionFee = config.usdceSpokePoolMaxExecutionFee;
        usdtSpokePoolMaxExecutionFee = config.usdtSpokePoolMaxExecutionFee;
        wethSpokePoolMaxExecutionFee = config.wethSpokePoolMaxExecutionFee;
        wbtcSpokePoolMaxExecutionFee = config.wbtcSpokePoolMaxExecutionFee;
        pathUsdSpokePoolMaxExecutionFee = config.pathUsdSpokePoolMaxExecutionFee;
        usdgSpokePoolMaxExecutionFee = config.usdgSpokePoolMaxExecutionFee;
        usdcSameChainMaxExecutionFee = config.usdcSameChainMaxExecutionFee;
        usdceSameChainMaxExecutionFee = config.usdceSameChainMaxExecutionFee;
        usdtSameChainMaxExecutionFee = config.usdtSameChainMaxExecutionFee;
        wethSameChainMaxExecutionFee = config.wethSameChainMaxExecutionFee;
        wbtcSameChainMaxExecutionFee = config.wbtcSameChainMaxExecutionFee;
        pathUsdSameChainMaxExecutionFee = config.pathUsdSameChainMaxExecutionFee;
        usdgSameChainMaxExecutionFee = config.usdgSameChainMaxExecutionFee;
        usdcCctpMaxExecutionFee = config.usdcCctpMaxExecutionFee;
        usdtOftMaxExecutionFee = config.usdtOftMaxExecutionFee;
        usdcCctpMaxFeeBps = config.usdcCctpMaxFeeBps;
        usdcStablePrice = config.usdcStablePrice;
        usdceStablePrice = config.usdceStablePrice;
        usdtStablePrice = config.usdtStablePrice;
        pathUsdStablePrice = config.pathUsdStablePrice;
        usdgStablePrice = config.usdgStablePrice;
        wethStablePrice = config.wethStablePrice;
        wbtcStablePrice = config.wbtcStablePrice;
        _disableInitializers();
    }

    /// @inheritdoc ICounterfactualBeacon
    /// @dev Dispatches over the configured token addresses; the only logic in this otherwise
    ///      configuration-only contract, and pure config reads. An unconfigured token slot is `address(0)`,
    ///      which returns 0 before any comparison can alias it. Every NAMED token is dispatched, volatile
    ///      ones included — they simply carry a zero price, which reads as unpriced. `wrappedNativeToken` is
    ///      not dispatched: it aliases either `weth` (already covered) or a volatile gas token (correctly
    ///      unpriced). See `ICounterfactualBeacon.stablePrice` for why it must not get its own price.
    function stablePrice(address token) external view returns (uint256) {
        if (token == address(0)) return 0;
        if (token == usdc) return usdcStablePrice;
        if (token == usdce) return usdceStablePrice;
        if (token == usdt) return usdtStablePrice;
        if (token == pathUsd) return pathUsdStablePrice;
        if (token == usdg) return usdgStablePrice;
        if (token == weth) return wethStablePrice;
        if (token == wbtc) return wbtcStablePrice;
        return 0;
    }
}
