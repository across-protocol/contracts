// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { ICounterfactualBeaconBase } from "./ICounterfactualBeaconBase.sol";

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
interface ICounterfactualBeacon is ICounterfactualBeaconBase {
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
}
