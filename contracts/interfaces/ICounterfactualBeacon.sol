// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { IBeacon } from "@openzeppelin/contracts/proxy/beacon/IBeacon.sol";

/**
 * @title ICounterfactualBeacon
 * @notice Global, per-chain registry and **beacon** for every counterfactual `BeaconProxy`:
 *         `implementation()` is the single implementation all proxies run; `upgradeRoot()` is the
 *         `(proxy, latestRoot)` tree authorizing best-effort per-proxy root updates. It is also the single
 *         source of every chain-specific value the leaves need (bridge endpoints, domains/EIDs, fee
 *         `signer`, token addresses), exposed as `public immutable` getters so leaves stay byte-identical
 *         across chains. Changing any value (or adding a token) is a UUPS upgrade; the proxy address never
 *         changes.
 * @dev `implementation()` is the **counterfactual** implementation (beacon target), not the registry's own.
 * @custom:security-contact bugs@across.to
 */
interface ICounterfactualBeacon is IBeacon {
    /// @notice Emitted when the admin sets the global implementation (the beacon target).
    event ImplementationSet(address indexed implementation);

    /// @notice Emitted when the admin sets the upgrade-tree root.
    event UpgradeRootSet(bytes32 indexed upgradeRoot);

    // `implementation()` is inherited from `IBeacon` — the canonical implementation every counterfactual
    // proxy runs (resolved live by each `BeaconProxy`).

    /// @notice Root of the `(proxy, latestRoot)` merkle tree authorizing per-proxy root updates.
    function upgradeRoot() external view returns (bytes32);

    // --- Authority --------------------------------------------------------------------------------------

    /// @notice Off-chain signer that authorizes runtime execution fees for every leaf implementation, and
    ///         the authority of the requirements plan. A zero value is fatal on every flow.
    function signer() external view returns (address);

    /// @notice The Across V5 `Gateway` on this chain.
    function gateway() external view returns (address);

    // --- Tokens -------------------------------------------------------------------------------------------
    //
    // Each is an input token (named by a leaf's `inputTokenGetter`) and a swap output token (its
    // `swapOutputTokenGetter`). Every one carries its own fee caps and price below; none is a fallback for
    // another, and a zero address means the token is not configured, so the route fails closed.

    /// @notice Native (Circle-issued or chain-canonical) USDC token address on this chain.
    function usdc() external view returns (address);

    /// @notice Bridged USDC.e token address, where it exists as a token distinct from `usdc()` — a
    ///         separate input token with its own caps (bridged USDC has no CCTP burn path). Zero where
    ///         USDC.e is absent or identical to native USDC.
    function usdce() external view returns (address);

    /// @notice USDT token address on this chain.
    function usdt() external view returns (address);

    /// @notice WBTC token address on this chain.
    function wbtc() external view returns (address);

    /// @notice Canonical WETH ERC-20 on this chain — an input token like `usdc`/`usdt`/`wbtc`, distinct
    ///         from `wrappedNativeToken()` (the wrapped GAS token; identical to WETH only on ETH-gas
    ///         chains). Lets leaves route actual WETH on chains whose native asset is not ETH.
    function weth() external view returns (address);

    /// @notice pathUSD on this chain — Tempo's TIP-20 settlement token, and an ordinary ERC-20 input token
    ///         like any other here. Tempo denominates gas in it, but that changes nothing for routing: there
    ///         is no wrapped form and no `msg.value` path, so every pathUSD route is a plain ERC-20 transfer
    ///         paying its fee in pathUSD. Being a stablecoin it carries a non-zero `pathUsdStablePrice()`.
    function pathUsd() external view returns (address);

    /// @notice USDG (Global Dollar) on this chain — a 6-decimal stablecoin, Robinhood only today. A plain
    ///         ERC-20 input token, priced like the other stablecoins.
    function usdg() external view returns (address);

    // --- Bridge endpoints and routing -----------------------------------------------------------------------

    /// @notice Across SpokePool on this chain.
    function spokePool() external view returns (address);

    /// @notice Wrapped native token (e.g. WETH) used as the SpokePool input token for native deposits.
    function wrappedNativeToken() external view returns (address);

    /// @notice Input token for the "native" SpokePool route: the native sentinel
    ///         (`0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE`) where the deposit is `msg.value` (wrapped to
    ///         `wrappedNativeToken()`), or an ERC-20 on chains with no native gas token. The SpokePool leaf
    ///         names this via `inputTokenGetter` and branches on the sentinel, so one leaf serves both.
    function nativeToken() external view returns (address);

    /// @notice SponsoredCCTPSrcPeriphery on this chain (sponsored CCTP route).
    function cctpSrcPeriphery() external view returns (address);

    /// @notice Circle CCTP v2 TokenMessenger on this chain (vanilla CCTP route).
    function cctpTokenMessenger() external view returns (address);

    /// @notice Circle CCTP source domain id for this chain (sponsored CCTP route).
    function cctpSourceDomain() external view returns (uint32);

    /// @notice SponsoredOFTSrcPeriphery (USDT0 today). OFT peripheries are single-token; the OFT leaf picks
    ///         which to use by this getter's selector, so another OFT token = another getter (beacon upgrade).
    function oftSrcPeriphery() external view returns (address);

    /// @notice LayerZero OFT source endpoint id for this chain.
    function oftSrcEid() external view returns (uint32);

    /// @notice The USDT0 `IOFT` on this chain — the `send` target of the V5 OFT bridge executor, committed as
    ///         its route's `bridgeEndpointGetter`. Distinct from `oftSrcPeriphery()` (the V4 sponsored-OFT
    ///         periphery). OFT endpoints are per-token, so another OFT asset means another getter.
    function usdtOft() external view returns (address);

    // --- Executors ------------------------------------------------------------------------------------------
    //
    // Committed as a route leaf's `executorGetter`; the prefunder requires the caller to be both
    // `gateway.currentExecutor()` and the address resolved here, so repointing a getter migrates a route.
    // Source-side only — the destination executor is committed directly by the route (folded into its
    // `dstStepId`), so it is never resolved off this beacon and has no getter here.

    /// @notice `CounterfactualSpokePoolBridgeExecutor`.
    function spokePoolDepositExecutor() external view returns (address);

    /// @notice `CounterfactualCCTPBridgeExecutor`.
    function cctpDepositExecutor() external view returns (address);

    /// @notice `CounterfactualOFTBridgeExecutor`.
    function oftDepositExecutor() external view returns (address);

    /// @notice `CounterfactualSameChainExecutor`.
    function sameChainExecutor() external view returns (address);

    // --- Execution-fee caps (input-token units) ---------------------------------------------------------------
    //
    // A leaf names which to enforce via its `maxExecutionFeeGetter` selector. For SpokePool this is the fixed
    // fee component (added to the leaf's `maxFeeBps` term). There is one entry per (token, bridge) pair that
    // can actually exist: SpokePool and same-chain take any supported token, whereas CCTP burns USDC only and
    // the OFT route is USDT0 only, so those two have a single cap each. Zero is a valid value — a fee-free
    // route, where any non-zero quoted fee is rejected.

    /// @notice Max (fixed) fee for the USDC SpokePool route.
    function usdcSpokePoolMaxExecutionFee() external view returns (uint256);

    /// @notice Max (fixed) fee for the USDC.e SpokePool route, in USDC.e units.
    function usdceSpokePoolMaxExecutionFee() external view returns (uint256);

    /// @notice Max (fixed) fee for the USDT SpokePool route.
    function usdtSpokePoolMaxExecutionFee() external view returns (uint256);

    /// @notice Max (fixed) fee for the WETH SpokePool route, in WETH units. On ETH-gas chains this also
    ///         caps the native (msg.value) route, since the wrapped gas token IS WETH there; non-ETH-gas
    ///         chains do not get wrapped-native routes.
    function wethSpokePoolMaxExecutionFee() external view returns (uint256);

    /// @notice Max (fixed) fee for the WBTC SpokePool route.
    function wbtcSpokePoolMaxExecutionFee() external view returns (uint256);

    /// @notice Max (fixed) fee for the pathUSD SpokePool route, in pathUSD units.
    function pathUsdSpokePoolMaxExecutionFee() external view returns (uint256);

    /// @notice Max (fixed) fee for the USDG SpokePool route.
    function usdgSpokePoolMaxExecutionFee() external view returns (uint256);

    /// @notice Max execution fee for the USDC same-chain route.
    function usdcSameChainMaxExecutionFee() external view returns (uint256);

    /// @notice Max execution fee for the USDC.e same-chain route.
    function usdceSameChainMaxExecutionFee() external view returns (uint256);

    /// @notice Max execution fee for the USDT same-chain route.
    function usdtSameChainMaxExecutionFee() external view returns (uint256);

    /// @notice Max execution fee for the WETH same-chain route.
    function wethSameChainMaxExecutionFee() external view returns (uint256);

    /// @notice Max execution fee for the WBTC same-chain route.
    function wbtcSameChainMaxExecutionFee() external view returns (uint256);

    /// @notice Max execution fee for the pathUSD same-chain route.
    function pathUsdSameChainMaxExecutionFee() external view returns (uint256);

    /// @notice Max execution fee for the USDG same-chain route.
    function usdgSameChainMaxExecutionFee() external view returns (uint256);

    /// @notice Max execution fee for the USDC CCTP route(s) — the only token CCTP burns.
    function usdcCctpMaxExecutionFee() external view returns (uint256);

    /// @notice Max execution fee for the USDT OFT route — the only token the OFT route carries.
    function usdtOftMaxExecutionFee() external view returns (uint256);

    /// @notice Cap on the submitter-chosen Circle fast-transfer fee (vanilla CCTP route), in bps of the
    ///         burned amount; 0 ⇒ standard transfers only. Bps, not token units, unlike every cap above.
    function usdcCctpMaxFeeBps() external view returns (uint256);

    // --- Prices ------------------------------------------------------------------------------------------
    //
    // Per-token USD price, 1e18-fixed and decimal-agnostic: the stable floor divides one by the other and
    // folds on-chain decimals, so one set of prices serves every chain. Zero marks the token unpriced and
    // SKIPS the floor for any pair touching it, leaving the authority-signed plan as the only protection.
    // Every supported token has a getter, volatile ones included: the `*StablePrice` name is the wire format
    // routes commit against, so the set stays complete even where the value is normally zero.

    /// @notice USD price of USDC, 1e18-fixed. Zero ⇒ unpriced (stable floor skipped).
    function usdcStablePrice() external view returns (uint256);

    /// @notice USD price of USDC.e, 1e18-fixed. Zero ⇒ unpriced (stable floor skipped).
    function usdceStablePrice() external view returns (uint256);

    /// @notice USD price of USDT, 1e18-fixed. Zero ⇒ unpriced (stable floor skipped).
    function usdtStablePrice() external view returns (uint256);

    /// @notice USD price of pathUSD, 1e18-fixed. A stablecoin, so normally non-zero.
    function pathUsdStablePrice() external view returns (uint256);

    /// @notice USD price of USDG, 1e18-fixed. A stablecoin, so normally non-zero.
    function usdgStablePrice() external view returns (uint256);

    /// @notice USD price of WETH, 1e18-fixed. Normally zero (volatile ⇒ unpriced).
    function wethStablePrice() external view returns (uint256);

    /// @notice USD price of WBTC, 1e18-fixed. Normally zero (volatile ⇒ unpriced).
    function wbtcStablePrice() external view returns (uint256);

    /// @notice The price the stable floor reads, dispatched over this beacon's configured token addresses.
    ///         Any other token — or a configured one whose `*StablePrice` is zero — is unpriced.
    function stablePrice(address token) external view returns (uint256);
}
