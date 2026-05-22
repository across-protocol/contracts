// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

/**
 * @title ICounterfactualDepositFactory
 * @notice Interface for the counterfactual deposit factory.
 * @dev The factory deploys clones of a fixed dispatcher (`CounterfactualDeposit`). Clone addresses
 *      derive from `(identityHash, initialRoot)`; the operational root lives in clone storage and
 *      can be migrated post-deploy without disturbing the address.
 * @custom:security-contact bugs@across.to
 */
interface ICounterfactualDepositFactory {
    /// @notice Emitted when a new clone is deployed and initialized.
    event DepositAddressCreated(address indexed depositAddress, bytes32 indexed identityHash, bytes32 initialRoot);

    /**
     * @notice Predicts the deterministic address of a clone before deployment.
     * @param identityHash keccak256(abi.encode(recipient, dstChainId, outputToken)) — the cross-chain identity.
     * @param initialRoot The genesis operational root the clone will be initialized with.
     * @return Predicted clone address.
     */
    function predictDepositAddress(bytes32 identityHash, bytes32 initialRoot) external view returns (address);

    /**
     * @notice Deploys a counterfactual deposit clone via CREATE2 and initializes its operational root.
     * @dev Salt = `keccak256(abi.encode(identityHash, initialRoot))`; immutable arg = `identityHash`.
     *      A different `initialRoot` produces a different CREATE2 address, blocking front-runs against
     *      a predicted address funded counterfactually.
     * @param identityHash Cross-chain identity hash.
     * @param initialRoot Genesis operational root.
     * @return depositAddress Address of the deployed clone.
     */
    function deploy(bytes32 identityHash, bytes32 initialRoot) external returns (address depositAddress);

    /**
     * @notice Forwards calldata to a deployed clone, bubbling up any revert.
     * @param depositAddress Address of the deployed clone.
     * @param executeCalldata Calldata to forward.
     */
    function execute(address depositAddress, bytes calldata executeCalldata) external payable;

    /**
     * @notice Deploys (reverts if already deployed) and executes in one transaction.
     * @param identityHash Cross-chain identity hash.
     * @param initialRoot Genesis operational root.
     * @param executeCalldata Calldata to forward to the clone.
     * @return depositAddress Address of the deployed clone.
     */
    function deployAndExecute(
        bytes32 identityHash,
        bytes32 initialRoot,
        bytes calldata executeCalldata
    ) external payable returns (address depositAddress);

    /**
     * @notice Deploys (if not already deployed) and executes in one transaction.
     * @param identityHash Cross-chain identity hash.
     * @param initialRoot Genesis operational root.
     * @param executeCalldata Calldata to forward to the clone.
     * @return depositAddress Address of the clone.
     */
    function deployIfNeededAndExecute(
        bytes32 identityHash,
        bytes32 initialRoot,
        bytes calldata executeCalldata
    ) external payable returns (address depositAddress);

    /**
     * @notice Deploys (if needed), migrates to a new operational root (if needed), and executes — all atomically.
     * @dev Ergonomic onboarding path for chains not enumerated in the genesis tree: the predicted clone
     *      address is identical on every chain, but the genesis operational root may not contain leaves
     *      for the current chain. This entrypoint deploys, migrates to the latest root, then executes.
     *      `migrate` is skipped if the clone is already at `newOperationalRoot`.
     * @param identityHash Cross-chain identity hash.
     * @param initialRoot Genesis operational root.
     * @param newOperationalRoot Target operational root after migration.
     * @param migrateProof Merkle proof for `(identityHash, newOperationalRoot)` against the registry's metaRoot.
     * @param executeCalldata Calldata to forward to the clone after migration.
     * @return depositAddress Address of the clone.
     */
    function deployAndMigrateAndExecute(
        bytes32 identityHash,
        bytes32 initialRoot,
        bytes32 newOperationalRoot,
        bytes32[] calldata migrateProof,
        bytes calldata executeCalldata
    ) external payable returns (address depositAddress);
}
