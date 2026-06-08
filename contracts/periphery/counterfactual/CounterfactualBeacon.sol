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
 * @notice Chain-specific configuration baked into a `CounterfactualBeacon` implementation at deploy time.
 * @dev Every field becomes a `public immutable` on the registry, so leaf implementations resolve the
 *      chain's bridge endpoints / tokens / fee signer from the registry instead of holding them as their
 *      own immutables — which keeps the leaf implementations byte-identical across chains. Per-chain
 *      addresses differ, so each chain deploys its own registry implementation with its own `ChainConfig`.
 */
struct CounterfactualChainConfig {
    address signer;
    address spokePool;
    address wrappedNativeToken;
    address cctpSrcPeriphery;
    address cctpTokenMessenger;
    uint32 cctpSourceDomain;
    address oftSrcPeriphery;
    uint32 oftSrcEid;
    address usdc;
    address usdt;
}

/**
 * @title CounterfactualBeacon
 * @notice Global, per-chain registry governing counterfactual proxies. It is the **beacon** for every
 *         counterfactual `BeaconProxy`: `implementation()` returns the single canonical implementation
 *         all proxies run, so setting it upgrades every proxy at once. It also holds the `upgradeRoot`
 *         (root of the `(proxy, latestRoot)` tree authorizing per-proxy root updates) and the chain's
 *         config (bridge endpoints, domains/EIDs, fee signer, token addresses), which leaf implementations
 *         read under delegatecall.
 * @dev Itself a UUPS proxy so its address is permanent (every `BeaconProxy` embeds it as the beacon,
 *      anchoring proxy addresses) while its logic can evolve. `implementation`/`upgradeRoot` are mutable
 *      storage (admin-set, meant to change). The chain config is `public immutable` (code, not storage);
 *      it is correctly readable through the proxy under delegatecall, but changing any value — or adding a
 *      token — requires deploying a new implementation and UUPS-upgrading to it (the proxy address stays
 *      constant). To keep the proxy address identical across chains, deploy the proxy against a uniform
 *      bootstrap implementation, then `upgradeToAndCall` to the chain-specific implementation.
 *
 *      `Ownable2Step` admin; no timelock in this implementation — the admin is effectively all-powerful
 *      (setting `implementation`, or upgrading to a new config, instantly retargets every proxy), so it
 *      must be a trusted multisig. NOTE: `implementation()` here is the **counterfactual** implementation
 *      (the beacon target), not the registry's own UUPS implementation.
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

    /// @inheritdoc ICounterfactualBeacon
    address public immutable signer;
    /// @inheritdoc ICounterfactualBeacon
    address public immutable spokePool;
    /// @inheritdoc ICounterfactualBeacon
    address public immutable wrappedNativeToken;
    /// @inheritdoc ICounterfactualBeacon
    address public immutable cctpSrcPeriphery;
    /// @inheritdoc ICounterfactualBeacon
    address public immutable cctpTokenMessenger;
    /// @inheritdoc ICounterfactualBeacon
    uint32 public immutable cctpSourceDomain;
    /// @inheritdoc ICounterfactualBeacon
    address public immutable oftSrcPeriphery;
    /// @inheritdoc ICounterfactualBeacon
    uint32 public immutable oftSrcEid;
    /// @inheritdoc ICounterfactualBeacon
    address public immutable usdc;
    /// @inheritdoc ICounterfactualBeacon
    address public immutable usdt;

    /// @param config The chain-specific configuration baked into this implementation (see
    ///        `CounterfactualChainConfig`). Each field becomes an immutable, named getter.
    constructor(CounterfactualChainConfig memory config) {
        signer = config.signer;
        spokePool = config.spokePool;
        wrappedNativeToken = config.wrappedNativeToken;
        cctpSrcPeriphery = config.cctpSrcPeriphery;
        cctpTokenMessenger = config.cctpTokenMessenger;
        cctpSourceDomain = config.cctpSourceDomain;
        oftSrcPeriphery = config.oftSrcPeriphery;
        oftSrcEid = config.oftSrcEid;
        usdc = config.usdc;
        usdt = config.usdt;
        _disableInitializers();
    }

    /**
     * @notice Initialize the registry's mutable storage.
     * @dev The chain config comes from the constructor (immutable); this only sets the admin and the two
     *      mutable knobs. NOTE: when deploying via the bootstrap→upgrade flow, the proxy is initialized by
     *      the bootstrap implementation and this `initialize` is never reached (the `initializer` slot is
     *      already consumed); set `implementation`/`upgradeRoot` via the owner setters after upgrading.
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
