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
 * @title CounterfactualBeaconBase
 * @notice The **logic** of the counterfactual registry/beacon: the mutable `implementation` (beacon target)
 *         every proxy runs, the `upgradeRoot` authorizing per-proxy root updates, UUPS upgradeability and the
 *         `Ownable2Step` admin. The chain-specific configuration (endpoints, tokens, fee signer, fee caps)
 *         lives in the derived `CounterfactualBeacon` as immutables. Splitting it out keeps the audit
 *         boundary clean: this base is the reviewable logic; a config-only change is a new derived contract
 *         that touches no logic here (see `CounterfactualBeacon`).
 * @dev Abstract — the config getters declared in `ICounterfactualBeacon` are implemented by the derived
 *      contract's immutables. A UUPS proxy, so the registry address is permanent (anchoring every
 *      `BeaconProxy`) while logic/config evolve. `Ownable2Step` admin (no timelock) — it can retarget every
 *      proxy instantly, so use a trusted multisig. `implementation()` is the beacon target, not the
 *      registry's own UUPS implementation.
 * @custom:security-contact bugs@across.to
 */
abstract contract CounterfactualBeaconBase is
    ICounterfactualBeacon,
    Initializable,
    UUPSUpgradeable,
    Ownable2StepUpgradeable
{
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

    /**
     * @notice Initialize the registry's mutable storage (chain config comes from the derived constructor).
     * @dev With the bootstrap→upgrade deploy the proxy is initialized by the bootstrap and this is never
     *      reached (initializer already consumed); set `implementation`/`upgradeRoot` via the owner setters.
     * @param owner_ The admin (use a multisig).
     * @param implementation_ Initial beacon target (may be address(0), set later via `setImplementation`).
     * @param upgradeRoot_ Initial upgrade-tree root (may be 0, set later).
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

    /// @dev A valid target is a contract whose immutable `BEACON()` points back here — guarding against
    ///      retargeting every proxy to logic bound to a different beacon (which would brick `updateRoot`).
    ///      The `try` tolerates non-conforming targets: they leave `boundBeacon == 0` and revert below.
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
