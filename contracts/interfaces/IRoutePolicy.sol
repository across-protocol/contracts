// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

/**
 * @title IRoutePolicy
 * @notice Interface for `RoutePolicy` — a per-chain merkle root that authorizes which routes
 *         a clone may execute. Clones reference a policy via their `routePolicyAddress` immutable
 *         arg and the dispatcher queries `activeRoot()` on every non-withdraw execute.
 * @custom:security-contact bugs@across.to
 */
interface IRoutePolicy {
    /// @notice Emitted on every successful root update.
    event Approved(bytes32 newRoot);

    /// @notice Returns the merkle root that currently authorizes routes on this chain.
    function activeRoot() external view returns (bytes32);

    /// @notice Replace the active root. Restricted to the policy owner.
    function approve(bytes32 newRoot) external;
}
