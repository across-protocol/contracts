// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { CloneArgs } from "../periphery/counterfactual/CounterfactualCloneArgs.sol";

/**
 * @title ICounterfactualDeposit
 * @notice Interface for the merkle-dispatched counterfactual deposit clone.
 * @custom:security-contact bugs@across.to
 */
interface ICounterfactualDeposit {
    /// @dev Caller-supplied `cloneArgs` did not hash to the clone's stored `argsHash`.
    error InvalidCloneArgs();
    /// @dev Merkle proof verification failed.
    error InvalidProof();

    /**
     * @notice Execute an implementation against the clone's bound route policy.
     * @param cloneArgs The clone's identity fields. Must hash to the clone's stored `argsHash`.
     * @param implementation The implementation contract to delegatecall.
     * @param routeParams ABI-encoded route parameters (impl-specific). Hashed into the leaf.
     * @param submitterData ABI-encoded data supplied by the caller at execution time.
     * @param proof Merkle proof for the leaf
     *              `keccak256(bytes.concat(keccak256(abi.encode(implementation, keccak256(routeParams)))))`
     *              against `IRoutePolicy(cloneArgs.routePolicyAddress).activeRoot(address(this))`.
     *              Implementations that bind to clone identity commit `(outputToken, destinationChainId)`
     *              inside their `routeParams` struct and check them at execute time.
     */
    function execute(
        CloneArgs calldata cloneArgs,
        address implementation,
        bytes calldata routeParams,
        bytes calldata submitterData,
        bytes32[] calldata proof
    ) external payable;
}
