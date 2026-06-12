// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

/**
 * @title IRoutePolicy
 * @notice Minimal interface a `RoutePolicy` must satisfy: return the merkle root that currently
 *         authorizes routes for a given clone. The `clone` argument lets implementations
 *         vary the root per-clone (overrides, isolation groups, etc.) without an interface change
 * @custom:security-contact bugs@across.to
 */
interface IRoutePolicy {
    /// @notice Returns the merkle root that authorizes routes for `clone` on this chain.
    function activeRoot(address clone) external view returns (bytes32);
}
