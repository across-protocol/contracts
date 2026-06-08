// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { IBeacon } from "@openzeppelin/contracts/proxy/beacon/IBeacon.sol";

/**
 * @title ICounterfactualBeacon
 * @notice Global, per-chain registry that governs how upgradeable counterfactual proxies behave. It is
 *         the **beacon** for every counterfactual `BeaconProxy`: `implementation()` (from `IBeacon`)
 *         returns the single canonical implementation all proxies run, so changing it upgrades every
 *         proxy at once (no per-proxy action). It also holds the `(proxy, latestRoot)` upgrade tree
 *         `root` that authorizes per-proxy root updates. Root updates are best-effort — there is no
 *         on-chain version/freshness gate.
 * @dev `implementation()` here is the **counterfactual** implementation (the beacon target) — distinct
 *      from the registry's own (UUPS) implementation.
 *
 *      Beyond the beacon role, this registry is the single source of every **chain-specific value** the
 *      leaf implementations need (bridge endpoints, domains/EIDs, the fee `signer`, and token addresses).
 *      These are exposed as `public immutable` getters so leaf implementations stay byte-identical across
 *      chains — a leaf names no chain-specific address itself. Because they are `immutable`, changing any
 *      of them (or adding a token) means deploying a new registry implementation and UUPS-upgrading to it;
 *      the proxy address — embedded in every `BeaconProxy` — never changes.
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

    /// @notice Resolved value of the "native or equivalent" SpokePool input-token route. Returns the
    ///         well-known native sentinel (`0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE`) on chains where
    ///         the deposit comes in as `msg.value` (and is wrapped to `wrappedNativeToken()` as the
    ///         SpokePool input), or an ERC-20 address on chains where the canonical gas-token route is
    ///         actually an ERC-20. The SpokePool leaf names this via `inputTokenGetter` and branches on
    ///         whether the returned value equals the sentinel — so one leaf serves both flavors.
    function nativeToken() external view returns (address);

    /// @notice SponsoredCCTPSrcPeriphery on this chain (sponsored CCTP route).
    function cctpSrcPeriphery() external view returns (address);

    /// @notice Circle CCTP v2 TokenMessenger on this chain (vanilla CCTP route).
    function cctpTokenMessenger() external view returns (address);

    /// @notice Circle CCTP source domain id for this chain (sponsored CCTP route).
    function cctpSourceDomain() external view returns (uint32);

    /// @notice SponsoredOFTSrcPeriphery on this chain (OFT route).
    function oftSrcPeriphery() external view returns (address);

    /// @notice LayerZero OFT source endpoint id for this chain.
    function oftSrcEid() external view returns (uint32);

    /// @notice USDC token address on this chain.
    function usdc() external view returns (address);

    /// @notice USDT token address on this chain.
    function usdt() external view returns (address);
}
