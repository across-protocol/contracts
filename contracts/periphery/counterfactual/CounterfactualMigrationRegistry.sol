// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { ICounterfactualMigrationRegistry } from "../../interfaces/ICounterfactualMigrationRegistry.sol";

/**
 * @title CounterfactualMigrationRegistry
 * @notice Single-purpose contract holding the admin-approved meta-merkle root used to authorize
 *         counterfactual operational-root upgrades.
 * @dev Deployed deterministically (no constructor args → same CREATE2 address on every chain). The
 *      initial owner is set to `tx.origin` at construction so that the deployment EOA — not the
 *      deterministic deployer contract — holds ownership; the deployment script then transfers
 *      ownership to the chain-specific governance address (multisig / timelock).
 *
 *      Migration security:
 *      - Only the current owner can rotate `metaRoot` via `setMetaRoot`.
 *      - Replacing `metaRoot` immediately invalidates every proof built against the previous value;
 *        replay protection comes from the contract holding the latest root only.
 *      - Clones consult this registry inside their `migrate` function via a hardcoded address
 *        constant (the registry is the same address on every chain).
 * @custom:security-contact bugs@across.to
 */
contract CounterfactualMigrationRegistry is ICounterfactualMigrationRegistry {
    /// @inheritdoc ICounterfactualMigrationRegistry
    bytes32 public metaRoot;

    /// @inheritdoc ICounterfactualMigrationRegistry
    address public owner;

    constructor() {
        owner = tx.origin;
        emit OwnershipTransferred(address(0), tx.origin);
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// @inheritdoc ICounterfactualMigrationRegistry
    function setMetaRoot(bytes32 newRoot) external onlyOwner {
        emit MetaRootUpdated(metaRoot, newRoot);
        metaRoot = newRoot;
    }

    /// @inheritdoc ICounterfactualMigrationRegistry
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }
}
