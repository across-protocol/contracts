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

    /// @notice Primary SponsoredOFTSrcPeriphery (USDT0 today). OFT peripheries are single-token; the OFT
    ///         leaf picks one by this getter's selector.
    function oftSrcPeriphery() external view returns (address);

    /// @notice USDC SponsoredOFTSrcPeriphery (`address(0)` where none is deployed).
    function oftUsdcPeriphery() external view returns (address);

    /// @notice LayerZero OFT source endpoint id for this chain.
    function oftSrcEid() external view returns (uint32);

    /// @notice USDC token address on this chain.
    function usdc() external view returns (address);

    /// @notice USDT token address on this chain.
    function usdt() external view returns (address);
}
