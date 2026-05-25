// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

/**
 * @title CloneIdentity
 * @notice Helper for `ICounterfactualImplementation` implementations that need to bind their
 *         authorized routes to specific clone identity values.
 * @dev The dispatcher's merkle leaf commits only `(implementation, keccak256(routeParams))` — it is
 *      agnostic to clone identity. Implementations that need to ensure a given leaf is only
 *      executable by clones with a specific `(outputToken, destinationChainId)` declare those
 *      fields in their `routeParams` struct and call `enforce(...)` at the top of `execute`. The
 *      check is a pair of pure calldata equality comparisons — the dispatcher-forwarded values
 *      from `cloneArgs` against the values committed inside `routeParams` (which the merkle proof
 *      already authenticated). Implementations that are agnostic to clone identity (e.g.
 *      SpokePool, where the relayer market refunds infeasible routes) simply don't call this
 *      library and don't include the binding fields in their `routeParams`.
 * @custom:security-contact bugs@across.to
 */
library CloneIdentity {
    /// @dev `routeParams.outputToken` does not match the clone's `outputToken`.
    error WrongOutputToken();
    /// @dev `routeParams.destinationChainId` does not match the clone's `destinationChainId`.
    error WrongDestinationChain();

    /**
     * @notice Revert unless the route-bound identity matches the clone's identity.
     * @param routeOutputToken         `outputToken` value committed inside `routeParams`.
     * @param cloneOutputToken         `outputToken` value forwarded by the dispatcher from `cloneArgs`.
     * @param routeDestinationChainId  `destinationChainId` committed inside `routeParams`.
     * @param cloneDestinationChainId  `destinationChainId` forwarded by the dispatcher from `cloneArgs`.
     */
    function enforce(
        bytes32 routeOutputToken,
        bytes32 cloneOutputToken,
        uint256 routeDestinationChainId,
        uint256 cloneDestinationChainId
    ) internal pure {
        if (routeOutputToken != cloneOutputToken) revert WrongOutputToken();
        if (routeDestinationChainId != cloneDestinationChainId) revert WrongDestinationChain();
    }
}
