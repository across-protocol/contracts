// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

/**
 * @title ICounterfactualDeposit
 * @notice Interface for the merkle-dispatched counterfactual deposit clone.
 * @custom:security-contact bugs@across.to
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
     */
    function execute(
        address implementation,
        bytes calldata params,
        bytes calldata submitterData,
        bytes32[] calldata proof
    ) external payable;

    /**
     * @notice Update `activeRoot` to `newRoot` (if not already there), then execute, atomically.
     * @dev Lets an executor activate a newly-added route and use it in one transaction. The root
     *      update is skipped when the proxy is already at `newRoot`, so this never reverts
     *      `RootUnchanged` for an already-current proxy.
     * @param newRoot The root to bring the proxy to before executing.
     * @param updateProof Merkle proof for the (proxy, newRoot) leaf in the beacon's upgrade tree.
     * @param implementation The implementation contract to delegatecall.
     * @param params ABI-encoded route parameters (hashed into the merkle leaf).
     * @param submitterData ABI-encoded data supplied by the caller at execution time.
     * @param executeProof Merkle proof for the (implementation, keccak256(params)) leaf.
     */
    function updateRootAndExecute(
        bytes32 newRoot,
        bytes32[] calldata updateProof,
        address implementation,
        bytes calldata params,
        bytes calldata submitterData,
        bytes32[] calldata executeProof
    ) external payable;
}
