// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { Ownable2StepUpgradeable } from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import { IUpgradeRegistry } from "../../interfaces/IUpgradeRegistry.sol";

/**
 * @title UpgradeRegistry
 * @notice Global, per-chain registry governing upgrades of counterfactual proxies. The admin sets the
 *         single `currentImplementation` (the shared logic every proxy can sync to) and the
 *         `upgradeRoot` (root of the `(proxy, latestRoot)` tree authorizing per-proxy root updates).
 * @dev Itself a UUPS proxy so its address is permanent (the bootstrap embeds it, anchoring every proxy
 *      address) while its logic can evolve. `Ownable2Step` admin; no timelock in this implementation —
 *      the admin is effectively all-powerful (a malicious `currentImplementation` can be synced onto
 *      any proxy), so it must be a trusted multisig.
 * @custom:security-contact bugs@across.to
 */
contract UpgradeRegistry is IUpgradeRegistry, Initializable, UUPSUpgradeable, Ownable2StepUpgradeable {
    /// @custom:storage-location erc7201:across.counterfactual.upgraderegistry.storage
    struct RegistryStorage {
        address currentImplementation;
        bytes32 upgradeRoot;
        uint256 version;
        uint256 minRequiredVersion;
    }

    /// @dev `minRequiredVersion` would exceed the current `version`.
    error InvalidMinRequiredVersion();

    // keccak256(abi.encode(uint256(keccak256("across.counterfactual.upgraderegistry.storage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant STORAGE_LOCATION = 0x237629bb159bfdd51cc72374c7cbd02c7575875eb81b93d58b674b910c5a4600;

    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the registry.
     * @param owner_ The admin (use a multisig).
     * @param currentImplementation_ Initial global implementation (may be address(0) and set later).
     * @param upgradeRoot_ Initial upgrade-tree root (may be 0 and set later).
     */
    function initialize(address owner_, address currentImplementation_, bytes32 upgradeRoot_) external initializer {
        __Ownable_init(owner_);
        __Ownable2Step_init();
        _setCurrentImplementation(currentImplementation_);
        _setUpgradeRoot(upgradeRoot_);
    }

    /// @inheritdoc IUpgradeRegistry
    function currentImplementation() external view returns (address) {
        return _getStorage().currentImplementation;
    }

    /// @inheritdoc IUpgradeRegistry
    function upgradeRoot() external view returns (bytes32) {
        return _getStorage().upgradeRoot;
    }

    /// @inheritdoc IUpgradeRegistry
    function version() external view returns (uint256) {
        return _getStorage().version;
    }

    /// @inheritdoc IUpgradeRegistry
    function minRequiredVersion() external view returns (uint256) {
        return _getStorage().minRequiredVersion;
    }

    /// @notice Set the global current implementation that proxies sync to.
    function setCurrentImplementation(address implementation) external onlyOwner {
        _setCurrentImplementation(implementation);
    }

    /// @notice Set the root of the `(proxy, latestRoot)` upgrade tree (bumps `version`).
    function setUpgradeRoot(bytes32 newUpgradeRoot) external onlyOwner {
        _setUpgradeRoot(newUpgradeRoot);
    }

    /// @notice Set the minimum `rootVersion` a proxy must have to execute. Must be `<= version`.
    function setMinRequiredVersion(uint256 newMinRequiredVersion) external onlyOwner {
        RegistryStorage storage $ = _getStorage();
        if (newMinRequiredVersion > $.version) revert InvalidMinRequiredVersion();
        $.minRequiredVersion = newMinRequiredVersion;
        emit MinRequiredVersionSet(newMinRequiredVersion);
    }

    function _setCurrentImplementation(address implementation) internal {
        _getStorage().currentImplementation = implementation;
        emit CurrentImplementationSet(implementation);
    }

    function _setUpgradeRoot(bytes32 newUpgradeRoot) internal {
        RegistryStorage storage $ = _getStorage();
        $.upgradeRoot = newUpgradeRoot;
        uint256 newVersion = $.version + 1;
        $.version = newVersion;
        emit UpgradeRootSet(newUpgradeRoot, newVersion);
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    function _getStorage() private pure returns (RegistryStorage storage $) {
        assembly {
            $.slot := STORAGE_LOCATION
        }
    }
}
