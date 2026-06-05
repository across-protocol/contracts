// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { IBeacon } from "@openzeppelin/contracts/proxy/beacon/IBeacon.sol";

/**
 * @title ICounterfactualBeacon
 * @notice Global, per-chain registry that governs how upgradeable counterfactual proxies behave. It is
 *         the **beacon** for every counterfactual `BeaconProxy`: `implementation()` (from `IBeacon`)
 *         returns the single canonical implementation all proxies run, so changing it upgrades every
 *         proxy at once (no per-proxy action). It also holds the `(proxy, latestRoot)` upgrade tree
 *         `root` and the `version` / `minRequiredVersion` that gate per-proxy root freshness.
 * @dev `implementation()` here is the **counterfactual** implementation (the beacon target) — distinct
 *      from the registry's own (UUPS) implementation.
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
}
