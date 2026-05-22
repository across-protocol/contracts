// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

/**
 * @title ICounterfactualDeposit
 * @notice Interface for the merkle-dispatched counterfactual deposit clone.
 * @custom:security-contact bugs@across.to
 */
interface ICounterfactualDeposit {
    /// @notice Emitted on first initialization, when the genesis operational root is installed.
    event Initialized(bytes32 initialRoot);

    /// @notice Emitted when the operational root is rotated by a successful `migrate`.
    event Migrated(bytes32 newRoot);

    /// @dev Merkle proof against the operational root failed.
    error InvalidProof();
    /// @dev Merkle proof against the registry's metaRoot failed.
    error InvalidMetaProof();
    /// @dev `initialize` was called more than once.
    error AlreadyInitialized();
    /// @dev `initialize` was called with `bytes32(0)` (which would authorize no leaves).
    error InvalidInitialRoot();
    /// @dev `migrate` was called with a `newRoot` equal to the current operational root.
    error NoOpMigration();

    /**
     * @notice Install the genesis operational root. Callable once, atomically with deploy by the factory.
     * @dev Reverts if already initialized or if `initialRoot == bytes32(0)`.
     * @param initialRoot The merkle root to install as the genesis operational root.
     */
    function initialize(bytes32 initialRoot) external;

    /**
     * @notice Execute an implementation by proving its inclusion in the clone's operational root.
     * @dev Leaf preimage includes `block.chainid`, so a single operational root is valid across every
     *      source chain; only leaves matching the current chain are provable.
     * @param implementation The implementation contract to delegatecall.
     * @param params ABI-encoded route parameters (hashed into the merkle leaf).
     * @param submitterData ABI-encoded data supplied by the caller at execution time.
     * @param proof Merkle proof for the `(block.chainid, implementation, keccak256(params))` leaf.
     */
    function execute(
        address implementation,
        bytes calldata params,
        bytes calldata submitterData,
        bytes32[] calldata proof
    ) external payable;

    /**
     * @notice Rotate the clone's operational root to `newRoot`, given a meta-proof against the registry's metaRoot.
     * @dev Permissionless given a valid proof. Reverts if `newRoot` matches the current operational root.
     * @param newRoot The new operational root to install.
     * @param metaProof Merkle proof for the `(identityHash, newRoot)` leaf against the registry's `metaRoot`.
     */
    function migrate(bytes32 newRoot, bytes32[] calldata metaProof) external;

    /// @notice The clone's current merkle root (what `execute` proofs are verified against).
    function merkleRoot() external view returns (bytes32);

    /// @notice The address of the migration registry consulted by `migrate` (immutable, same on every chain).
    function migrationRegistry() external view returns (address);
}
