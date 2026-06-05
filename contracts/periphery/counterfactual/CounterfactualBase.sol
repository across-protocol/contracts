// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { ERC1967Utils } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import { MerkleProof } from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import { IUpgradeRegistry } from "../../interfaces/IUpgradeRegistry.sol";

/**
 * @title CounterfactualBase
 * @notice Shared base for the upgradeable counterfactual proxy implementations (the bootstrap and the
 *         CounterfactualDeposit dispatcher).
 * @dev A UUPS-upgradeable contract whose only state is `activeRoot` (the merkle root authorizing this
 *      proxy's deposit routes), held in an ERC-7201 namespaced slot. There is no owner/admin: upgrades
 *      are governed by the global `UpgradeRegistry` (immutable, embedded in bytecode):
 *        - `syncImplementation()` (permissionless) upgrades to the registry's `currentImplementation`;
 *          `_authorizeUpgrade` enforces the target equals it, so a proxy can only ever run the
 *          admin-curated implementation.
 *        - `updateRoot(newRoot, proof)` (permissionless) sets `activeRoot` to a value the registry's
 *          `(proxy, latestRoot)` tree authorizes.
 * @custom:security-contact bugs@across.to
 */
abstract contract CounterfactualBase is Initializable, UUPSUpgradeable {
    /// @custom:storage-location erc7201:across.counterfactual.upgradeable.storage
    struct CounterfactualStorage {
        bytes32 activeRoot;
        uint256 rootVersion;
    }

    // keccak256(abi.encode(uint256(keccak256("across.counterfactual.upgradeable.storage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant STORAGE_LOCATION = 0x5b89d334b964a560e5498fb6b9c95b4213116f116bbd1e59c9c85ba952217700;

    /// @notice The global per-chain registry governing this proxy's implementation and root updates.
    IUpgradeRegistry public immutable UPGRADE_REGISTRY;

    /// @notice Emitted when `activeRoot` is updated via the upgrade tree (carries the stamped version).
    event RootUpdated(bytes32 newRoot, uint256 rootVersion);

    /// @dev Merkle proof against the registry's `(proxy, latestRoot)` tree failed.
    error InvalidUpgradeProof();
    /// @dev Upgrade target is not the registry's `currentImplementation`.
    error UnauthorizedImplementation();
    /// @dev Upgrade target equals the current implementation (no-op).
    error ImplementationUnchanged();
    /// @dev Neither the root nor the version would change (no-op).
    error RootUnchanged();
    /// @dev `execute` called while the proxy is not running the registry's `currentImplementation`.
    error StaleImplementation();
    /// @dev `execute` called while the proxy's `rootVersion` is below the registry's `minRequiredVersion`.
    error StaleRoot();

    constructor(IUpgradeRegistry registry) {
        UPGRADE_REGISTRY = registry;
        _disableInitializers();
    }

    /// @notice The merkle root authorizing this proxy's deposit routes.
    function activeRoot() public view returns (bytes32) {
        return _getStorage().activeRoot;
    }

    /// @notice The registry version stamped on this proxy at its last root update (or at deploy).
    function rootVersion() public view returns (uint256) {
        return _getStorage().rootVersion;
    }

    /// @notice Permissionlessly upgrade this proxy to the registry's `currentImplementation`.
    /// @dev No proof needed: a proxy can only ever land on the admin-curated current value, and there is
    ///      no old value to replay (a single registry slot makes the implementation monotonic).
    function syncImplementation() external {
        upgradeToAndCall(UPGRADE_REGISTRY.currentImplementation(), "");
    }

    /// @notice Update `activeRoot`, proving `(address(this), newRoot)` is in the registry's upgrade tree,
    ///         and stamp the proxy's `rootVersion` with the registry's current version.
    /// @dev Re-applying the *same* root is allowed when it advances the version (lets an unaffected proxy
    ///      climb to a higher `minRequiredVersion`); only a true no-op (same root AND same version) reverts.
    function updateRoot(bytes32 newRoot, bytes32[] calldata proof) external {
        CounterfactualStorage storage $ = _getStorage();
        uint256 newVersion = UPGRADE_REGISTRY.version();
        if (newRoot == $.activeRoot && newVersion == $.rootVersion) revert RootUnchanged();
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(address(this), newRoot))));
        if (!MerkleProof.verify(proof, UPGRADE_REGISTRY.upgradeRoot(), leaf)) revert InvalidUpgradeProof();
        $.activeRoot = newRoot;
        $.rootVersion = newVersion;
        emit RootUpdated(newRoot, newVersion);
    }

    function _setActiveRoot(bytes32 root) internal {
        _getStorage().activeRoot = root;
    }

    function _setRootVersion(uint256 version) internal {
        _getStorage().rootVersion = version;
    }

    /// @dev Gate for `execute` (the deposit/withdraw path). Reverts unless the proxy runs the registry's
    ///      current implementation AND its `rootVersion >= minRequiredVersion`. NOT applied to
    ///      `syncImplementation` / `updateRoot` — those are the remediation paths for a stale proxy.
    function _requireUpToDate() internal view {
        if (ERC1967Utils.getImplementation() != UPGRADE_REGISTRY.currentImplementation()) revert StaleImplementation();
        if (_getStorage().rootVersion < UPGRADE_REGISTRY.minRequiredVersion()) revert StaleRoot();
    }

    /// @dev Gate upgrades on the registry: the only allowed target is the current global implementation,
    ///      and it must differ from the implementation already in use (no-op upgrades revert).
    function _authorizeUpgrade(address newImplementation) internal view override {
        if (newImplementation != UPGRADE_REGISTRY.currentImplementation()) revert UnauthorizedImplementation();
        if (newImplementation == ERC1967Utils.getImplementation()) revert ImplementationUnchanged();
    }

    function _getStorage() private pure returns (CounterfactualStorage storage $) {
        assembly {
            $.slot := STORAGE_LOCATION
        }
    }
}
