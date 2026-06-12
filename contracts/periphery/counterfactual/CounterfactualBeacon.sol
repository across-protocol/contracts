// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { Ownable2StepUpgradeable } from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import { IBeacon } from "@openzeppelin/contracts/proxy/beacon/IBeacon.sol";
import { ICounterfactualBeacon } from "../../interfaces/ICounterfactualBeacon.sol";

/// @dev Minimal view used to verify a candidate beacon target is bound to this beacon — every
///      counterfactual implementation embeds its beacon as the immutable `BEACON` (for `updateRoot`).
interface IBeaconTarget {
    function BEACON() external view returns (address);
}

/**
 * @title CounterfactualBeacon
 * @notice Global, per-chain registry governing counterfactual proxies. It is the **beacon** for every
 *         counterfactual `BeaconProxy`: `implementation()` returns the single canonical implementation
 *         all proxies run, so setting it upgrades every proxy at once. It also holds the `upgradeRoot`
 *         (root of the `(proxy, latestRoot)` tree authorizing per-proxy root updates).
 * @dev Itself a UUPS proxy so its address is permanent (every `BeaconProxy` embeds it as the beacon,
 *      anchoring proxy addresses) while its logic can evolve. `Ownable2Step` admin; no timelock in this
 *      implementation — the admin is effectively all-powerful (setting `implementation` instantly
 *      retargets every proxy), so it must be a trusted multisig. NOTE: `implementation()` here is the
 *      **counterfactual** implementation (the beacon target), not the registry's own UUPS implementation.
 * @custom:security-contact bugs@across.to
 */
contract CounterfactualBeacon is ICounterfactualBeacon, Initializable, UUPSUpgradeable, Ownable2StepUpgradeable {
    /// @custom:storage-location erc7201:across.counterfactual.beacon.storage
    struct RegistryStorage {
        address implementation;
        bytes32 upgradeRoot;
    }

    /// @dev Implementation target is not a contract.
    error NotAContract();
    /// @dev Implementation target's `BEACON()` does not point back at this beacon.
    error WrongBeacon();

    // keccak256(abi.encode(uint256(keccak256("across.counterfactual.beacon.storage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant STORAGE_LOCATION = 0xb8f0bb8c74633417634f6191ee000dac3f927914fa2e1d714b73a72668a01500;

    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the registry.
     * @param owner_ The admin (use a multisig).
     * @param implementation_ Initial global implementation / beacon target (may be address(0) and set
     *        later via `setImplementation` — the deploy flow is registry → impl → `setImplementation`).
     * @param upgradeRoot_ Initial upgrade-tree root (may be 0 and set later).
     */
    function initialize(address owner_, address implementation_, bytes32 upgradeRoot_) external initializer {
        __Ownable_init(owner_);
        __Ownable2Step_init();
        // Allow `address(0)` for lazy init (the standard deploy flow is beacon → impl → setImplementation);
        // otherwise the target must be a contract bound to this beacon, matching `setImplementation`.
        if (implementation_ != address(0)) _validateImplementation(implementation_);
        _setImplementation(implementation_);
        _setUpgradeRoot(upgradeRoot_);
    }

    /// @inheritdoc IBeacon
    /// @dev The counterfactual implementation every `BeaconProxy` resolves and delegatecalls.
    function implementation() external view returns (address) {
        return _getStorage().implementation;
    }

    /// @inheritdoc ICounterfactualBeacon
    function upgradeRoot() external view returns (bytes32) {
        return _getStorage().upgradeRoot;
    }

    /// @notice Set the global implementation (the beacon target) every proxy runs. Must be a contract
    ///         bound to this beacon; setting it instantly retargets all counterfactual proxies.
    function setImplementation(address newImplementation) external onlyOwner {
        _validateImplementation(newImplementation);
        _setImplementation(newImplementation);
    }

    /// @notice Set the root of the `(proxy, latestRoot)` upgrade tree.
    function setUpgradeRoot(bytes32 newUpgradeRoot) external onlyOwner {
        _setUpgradeRoot(newUpgradeRoot);
    }

    /// @dev A valid beacon target must be a contract whose immutable `BEACON()` points back at this
    ///      beacon. Catches the catastrophic admin error of retargeting every proxy to logic bound to a
    ///      different beacon (which would silently brick `updateRoot` and risk storage-layout drift). The
    ///      `try` tolerates non-conforming targets — they leave `boundBeacon == address(0)` and revert below.
    function _validateImplementation(address impl) private view {
        if (impl.code.length == 0) revert NotAContract();
        address boundBeacon;
        try IBeaconTarget(impl).BEACON() returns (address b) {
            boundBeacon = b;
        } catch {}
        if (boundBeacon != address(this)) revert WrongBeacon();
    }

    function _setImplementation(address newImplementation) internal {
        _getStorage().implementation = newImplementation;
        emit ImplementationSet(newImplementation);
    }

    function _setUpgradeRoot(bytes32 newUpgradeRoot) internal {
        _getStorage().upgradeRoot = newUpgradeRoot;
        emit UpgradeRootSet(newUpgradeRoot);
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    function _getStorage() private pure returns (RegistryStorage storage $) {
        assembly {
            $.slot := STORAGE_LOCATION
        }
    }
}
