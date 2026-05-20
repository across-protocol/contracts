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
    /// @dev Leaf's `(destinationChainId, outputToken)` did not match the clone's identity.
    error InvalidIdentity();
    /// @dev Merkle proof verification failed.
    error InvalidProof();
    /// @dev `params` shorter than the required `(destinationChainId, outputToken)` prefix.
    error ParamsTooShort();

    /**
     * @notice Execute an implementation against the clone's bound route policy.
     * @param cloneArgs The clone's identity fields. Must hash to the clone's stored `argsHash`.
     * @param implementation The implementation contract to delegatecall.
     * @param params ABI-encoded route parameters. First two fields must be
     *               `(uint256 destinationChainId, bytes32 outputToken)`.
     * @param submitterData ABI-encoded data supplied by the caller at execution time.
     * @param proof Merkle proof for the leaf `keccak256(bytes.concat(keccak256(abi.encode(implementation, keccak256(params)))))`
     *              against `RoutePolicy(cloneArgs.routePolicyAddress).activeRoot()`.
     */
    function execute(
        CloneArgs calldata cloneArgs,
        address implementation,
        bytes calldata params,
        bytes calldata submitterData,
        bytes32[] calldata proof
    ) external payable;
}
