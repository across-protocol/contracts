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

    // --- Chain-specific config (immutable; read by leaf implementations under delegatecall) ---

    /// @notice Off-chain signer that authorizes runtime execution fees for every leaf implementation.
    function signer() external view returns (address);

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

    /// @notice Native (Circle-issued or chain-canonical) USDC token address on this chain.
    function usdc() external view returns (address);

    /// @notice Bridged USDC.e token address, where it exists as a token distinct from `usdc()` — a
    ///         separate input token with its own cap, serving SpokePool routes only (bridged USDC has
    ///         no CCTP burn path). Zero where USDC.e is absent or identical to native USDC.
    function usdce() external view returns (address);

    /// @notice USDT token address on this chain.
    function usdt() external view returns (address);

    /// @notice WBTC token address on this chain.
    function wbtc() external view returns (address);

    /// @notice Canonical WETH ERC-20 on this chain — an input token like `usdc`/`usdt`/`wbtc`, distinct
    ///         from `wrappedNativeToken()` (the wrapped GAS token; identical to WETH only on ETH-gas
    ///         chains). Lets leaves route actual WETH on chains whose native asset is not ETH.
    function weth() external view returns (address);

    // --- Per-(token, bridge) execution-fee caps (input-token units). A leaf names which to enforce via its
    //     `maxExecutionFeeGetter` selector. Illustrative set; for SpokePool this is the fixed fee component. ---

    /// @notice Max execution fee for the USDC CCTP route(s).
    function usdcCctpMaxExecutionFee() external view returns (uint256);

    /// @notice Cap on the submitter-chosen Circle fast-transfer fee (vanilla CCTP route), in bps of the
    ///         burned amount; 0 ⇒ standard transfers only.
    function usdcCctpMaxFeeBps() external view returns (uint256);

    /// @notice Max execution fee for the USDT OFT route.
    function usdtOftMaxExecutionFee() external view returns (uint256);

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

    // --- V5 config -----------------------------------------------------------------------------------------
    //
    // Values the Across V5 counterfactual vertical resolves off this beacon, mirroring the getter set of the
    // V5 repo's `MockBeacon`. The getter NAME is the wire format: a V5 `CounterfactualRoute` / `Template`
    // commits `bytes4` selectors (`inputTokenGetter`, `executorGetter`, `bridgeEndpointGetter`,
    // `swapOutputTokenGetter`, `maxExecutionFeeGetter`, `cctpMaxFeeBpsGetter`) that V5's `BeaconLib` resolves
    // by staticcall — so renaming any of these orphans every route committed against it. Zero means the
    // route is not configured and fails closed (`RouteNotConfigured`) for address getters; for the fee caps
    // and stable prices zero is a VALID configured value (see each group below).

    /// @notice The Across V5 `Gateway` on this chain, resolved by the V5 prefunder to build the live path.
    function gateway() external view returns (address);

    /// @notice The USDT0 `IOFT` on this chain — the `send` target of V5's `CounterfactualOFTBridgeExecutor`,
    ///         committed as its route's `bridgeEndpointGetter`. Distinct from `oftSrcPeriphery()` (the V4
    ///         sponsored-OFT periphery). OFT endpoints are per-token, so another OFT asset means another
    ///         getter.
    function usdtOft() external view returns (address);

    // --- V5 executors. Committed as a route leaf's `executorGetter`; V5's prefunder requires the caller to
    //     be both `gateway.currentExecutor()` and the address resolved here, so repointing migrates a route.

    /// @notice V5 `CounterfactualSpokePoolBridgeExecutor`.
    function spokePoolDepositExecutor() external view returns (address);

    /// @notice V5 `CounterfactualCCTPBridgeExecutor`.
    function cctpDepositExecutor() external view returns (address);

    /// @notice V5 `CounterfactualOFTBridgeExecutor`.
    function oftDepositExecutor() external view returns (address);

    /// @notice V5 `CounterfactualSameChainExecutor`.
    function sameChainExecutor() external view returns (address);

    /// @notice V5 `CounterfactualDestinationExecutor`. Never resolved on-chain — a route commits it directly
    ///         as `dstExecutor` folded into `dstStepId` — but published here so tooling reads one source of
    ///         truth. Note that executor is itself constructor-bound to this beacon, so the two must agree.
    function destinationExecutor() external view returns (address);

    // --- Remaining per-(token, bridge) V5 execution-fee caps, in funded-token units. Zero is a valid value:
    //     a fee-free route. (The USDC CCTP, USDT OFT and SpokePool caps are declared above, shared with V4.)

    /// @notice Max execution fee for the USDT CCTP route.
    function usdtCctpMaxExecutionFee() external view returns (uint256);

    /// @notice Max execution fee for the WETH CCTP route.
    function wethCctpMaxExecutionFee() external view returns (uint256);

    /// @notice Max execution fee for the USDC.e CCTP route.
    function usdceCctpMaxExecutionFee() external view returns (uint256);

    /// @notice Max execution fee for the USDC OFT route.
    function usdcOftMaxExecutionFee() external view returns (uint256);

    /// @notice Max execution fee for the WETH OFT route.
    function wethOftMaxExecutionFee() external view returns (uint256);

    /// @notice Max execution fee for the USDC.e OFT route.
    function usdceOftMaxExecutionFee() external view returns (uint256);

    /// @notice Max execution fee for the USDC same-chain route.
    function usdcSameChainMaxExecutionFee() external view returns (uint256);

    /// @notice Max execution fee for the USDT same-chain route.
    function usdtSameChainMaxExecutionFee() external view returns (uint256);

    /// @notice Max execution fee for the WETH same-chain route.
    function wethSameChainMaxExecutionFee() external view returns (uint256);

    /// @notice Max execution fee for the USDC.e same-chain route.
    function usdceSameChainMaxExecutionFee() external view returns (uint256);

    // --- Per-token USD stable prices, 1e18-fixed and decimal-agnostic: V5's `FloorLib.stableFloor` divides
    //     one by the other and folds on-chain decimals, so one price pair serves every chain. Zero marks the
    //     token unpriced (volatile) and SKIPS the stable floor for any pair touching it — the normal setting
    //     for WETH, whose output is then protected only by the authority-signed plan.

    /// @notice USD price of USDC, 1e18-fixed. Zero ⇒ unpriced (stable floor skipped).
    function usdcStablePrice() external view returns (uint256);

    /// @notice USD price of USDT, 1e18-fixed. Zero ⇒ unpriced (stable floor skipped).
    function usdtStablePrice() external view returns (uint256);

    /// @notice USD price of WETH, 1e18-fixed. Normally zero (unpriced/volatile).
    function wethStablePrice() external view returns (uint256);

    /// @notice USD price of USDC.e, 1e18-fixed. Zero ⇒ unpriced (stable floor skipped).
    function usdceStablePrice() external view returns (uint256);

    /// @notice The price V5's `FloorLib` reads, dispatched over this beacon's configured token addresses.
    ///         Any other token — or a configured one whose `*StablePrice` is zero — is unpriced.
    function stablePrice(address token) external view returns (uint256);
}
