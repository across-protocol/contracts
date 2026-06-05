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

    /// @notice Emitted when the admin sets the upgrade-tree root (carries the new monotonic version).
    event UpgradeRootSet(bytes32 indexed upgradeRoot, uint256 indexed version);

    /// @notice Emitted when the admin sets the minimum root version required to execute.
    event MinRequiredVersionSet(uint256 minRequiredVersion);

    /// @notice The canonical implementation every counterfactual proxy may sync to.
    function currentImplementation() external view returns (address);

    /// @notice Root of the `(proxy, latestRoot)` merkle tree authorizing per-proxy root updates.
    function upgradeRoot() external view returns (bytes32);

    /// @notice Monotonic counter, incremented on every upgrade-root update. A proxy stamps this value
    ///         as its `rootVersion` whenever it updates its root (and at deploy).
    function version() external view returns (uint256);

    /// @notice Minimum `rootVersion` a proxy must have to `execute`. Admin-set, always `<= version`.
    function minRequiredVersion() external view returns (uint256);
}
