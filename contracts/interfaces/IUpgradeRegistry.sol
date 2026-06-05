// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

/**
 * @title IUpgradeRegistry
 * @notice Global, per-chain registry that governs how upgradeable counterfactual proxies may be
 *         upgraded. Holds the single `currentImplementation` every proxy syncs to (global, shared
 *         logic) and the root of the `(proxy, latestRoot)` merkle tree authorizing per-proxy
 *         `activeRoot` updates.
 * @custom:security-contact bugs@across.to
 */
interface IUpgradeRegistry {
    /// @notice Emitted when the admin sets the global current implementation.
    event CurrentImplementationSet(address indexed implementation);

    /// @notice Emitted when the admin sets the upgrade-tree root.
    event UpgradeRootSet(bytes32 indexed upgradeRoot);

    /// @notice The canonical implementation every counterfactual proxy may sync to.
    function currentImplementation() external view returns (address);

    /// @notice Root of the `(proxy, latestRoot)` merkle tree authorizing per-proxy root updates.
    function upgradeRoot() external view returns (bytes32);
}
