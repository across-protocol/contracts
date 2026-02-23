// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

/**
 * @title ICounterfactualDeposit
 * @notice Interface for the merkle-dispatched counterfactual deposit clone.
 */
interface ICounterfactualDeposit {
    /// @dev Merkle proof verification failed.
    error InvalidProof();

    /**
     * @notice Execute an implementation by proving its inclusion in the clone's merkle tree.
     * @param implementation The implementation contract to delegatecall.
     * @param params ABI-encoded route parameters (hashed into the merkle leaf).
     * @param submitterData ABI-encoded data supplied by the caller at execution time.
     * @param proof Merkle proof for the (implementation, keccak256(params)) leaf.
     * @return Result bytes from the implementation.
     */
    function execute(
        address implementation,
        bytes calldata params,
        bytes calldata submitterData,
        bytes32[] calldata proof
    ) external payable returns (bytes memory);
}
