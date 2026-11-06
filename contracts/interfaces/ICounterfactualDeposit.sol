// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { ICounterfactualBeaconBase } from "./ICounterfactualBeaconBase.sol";

/**
 * @title ICounterfactualDeposit
 * @notice Interface for the merkle-dispatched counterfactual deposit clone.
 * @custom:security-contact bugs@across.to
 */
interface ICounterfactualDeposit {
    /// @dev Merkle proof verification failed.
    error InvalidProof();

    /// @dev Merkle proof against the beacon's `(proxy, latestRoot)` upgrade tree failed.
    error InvalidUpgradeProof();

    /// @dev New root equals the current `activeRoot` (no-op).
    error RootUnchanged();

    /// @notice Emitted when `activeRoot` is updated via the beacon's upgrade tree.
    event RootUpdated(bytes32 newRoot);

    /// @notice The per-chain registry/beacon this proxy resolves its implementation from, and the source
    ///         of the `upgradeRoot` that `updateRoot` proves against.
    /// @dev Typed to the registry surface only — the dispatcher reads no chain config, so this is
    ///      `ICounterfactualBeaconBase` rather than a config interface.
    function BEACON() external view returns (ICounterfactualBeaconBase);

    /// @notice The merkle root authorizing this proxy's deposit routes.
    function activeRoot() external view returns (bytes32);

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

    /**
     * @notice Update `activeRoot` to `newRoot`, proving `(address(this), newRoot)` is in the beacon's
     *         upgrade tree.
     * @dev Permissionless. Root updates are best-effort — a proxy keeps its `activeRoot` until someone
     *      updates it; there is no on-chain version or min-version gate.
     * @param newRoot The root to bring the proxy to.
     * @param proof Merkle proof for the (proxy, newRoot) leaf in the beacon's upgrade tree.
     */
    function updateRoot(bytes32 newRoot, bytes32[] calldata proof) external;
}
