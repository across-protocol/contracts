// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { ICounterfactualMigrationRegistry } from "../../interfaces/ICounterfactualMigrationRegistry.sol";

/**
 * @title CounterfactualMigrationRegistry
 * @notice Single-purpose contract holding the admin-approved meta-merkle root used to authorize
 *         counterfactual operational-root upgrades.
 * @dev Deployed deterministically (via the universal deployer at `0x4e59…956C`). Initial owner and
 *      meta-root are committed as constructor args so that a front-runner cannot race the legitimate
 *      deployer on a new chain: a deployer using a different `(initialOwner, initialMetaRoot)` tuple
 *      produces different initCode → different CREATE2 address → no collision with the legitimate
 *      deployment. For cross-chain address consistency, the same `(initialOwner, initialMetaRoot)`
 *      tuple must be passed on every chain (typically a deterministically-deployed multisig as owner
 *      and `bytes32(0)` as the initial meta-root).
 *
 *      Migration security:
 *      - Only the current owner can rotate `metaRoot` via `setMetaRoot`.
 *      - Replacing `metaRoot` immediately invalidates every proof built against the previous value;
 *        replay protection comes from the contract holding the latest root only.
 *      - Clones consult this registry inside their `migrate` function via an immutable address set in
 *        the dispatcher (the registry is at the same address on every chain).
 * @custom:security-contact bugs@across.to
 */
contract CounterfactualMigrationRegistry is ICounterfactualMigrationRegistry {
    /// @inheritdoc ICounterfactualMigrationRegistry
    bytes32 public metaRoot;

    /// @inheritdoc ICounterfactualMigrationRegistry
    address public owner;

    constructor(address initialOwner, bytes32 initialMetaRoot) {
        if (initialOwner == address(0)) revert ZeroAddress();
        owner = initialOwner;
        emit OwnershipTransferred(address(0), initialOwner);

        if (initialMetaRoot != bytes32(0)) {
            metaRoot = initialMetaRoot;
            emit MetaRootUpdated(bytes32(0), initialMetaRoot);
        }
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
