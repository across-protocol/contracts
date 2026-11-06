// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { IBeacon } from "@openzeppelin/contracts/proxy/beacon/IBeacon.sol";

/**
 * @title ICounterfactualBeaconBase
 * @notice The registry/beacon's own surface: the `implementation()` every counterfactual `BeaconProxy`
 *         resolves, and the `upgradeRoot()` authorizing best-effort per-proxy root updates. This is what
 *         `CounterfactualBeaconBase` implements and all a consumer of the beacon-as-beacon needs; the
 *         chain-specific configuration lives in a config interface extending this one
 *         (`ICounterfactualBeacon` for this repo's beacon).
 * @dev Split out from `ICounterfactualBeacon` deliberately: `CounterfactualBeaconBase` is pure registry
 *      logic and should not inherit an obligation to expose config getters it does not own. Keeping them
 *      apart is also what lets a config surface be declared independently of this repo's v4 getter set.
 * @custom:security-contact bugs@across.to
 */
interface ICounterfactualBeaconBase is IBeacon {
    /// @notice Emitted when the admin sets the global implementation (the beacon target).
    event ImplementationSet(address indexed implementation);

    /// @notice Emitted when the admin sets the upgrade-tree root.
    event UpgradeRootSet(bytes32 indexed upgradeRoot);

    // `implementation()` is inherited from `IBeacon` — the canonical implementation every counterfactual
    // proxy runs (resolved live by each `BeaconProxy`).

    /// @notice Root of the `(proxy, latestRoot)` merkle tree authorizing per-proxy root updates.
    function upgradeRoot() external view returns (bytes32);
}
