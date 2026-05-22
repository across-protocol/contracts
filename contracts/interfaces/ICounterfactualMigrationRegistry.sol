// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

/**
 * @title ICounterfactualMigrationRegistry
 * @notice Holds the admin-approved meta-merkle root that authorizes counterfactual operational-root upgrades.
 * @custom:security-contact bugs@across.to
 */
interface ICounterfactualMigrationRegistry {
    /// @notice Emitted when the meta-merkle root is rotated by the owner.
    event MetaRootUpdated(bytes32 oldRoot, bytes32 newRoot);

    /// @notice Emitted when ownership of the registry is transferred.
    event OwnershipTransferred(address indexed oldOwner, address indexed newOwner);

    /// @dev Caller is not the current owner.
    error NotOwner();
    /// @dev New owner cannot be the zero address.
    error ZeroAddress();

    /// @notice Current meta-merkle root. Each leaf authorizes a `(identityHash, newOperationalRoot)` pair.
    function metaRoot() external view returns (bytes32);

    /// @notice Current owner. Only this address may call `setMetaRoot` or `transferOwnership`.
    function owner() external view returns (address);

    /**
     * @notice Replace the meta-merkle root. Proofs against the previous root immediately stop verifying.
     * @param newRoot The new meta-merkle root.
     */
    function setMetaRoot(bytes32 newRoot) external;

    /**
     * @notice Transfer ownership of the registry to a new address.
     * @param newOwner Address that will hold ownership after this call.
     */
    function transferOwnership(address newOwner) external;
}
