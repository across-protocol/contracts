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
 * @notice Chain-specific config baked into a `CounterfactualBeacon` implementation as `public immutable`s,
 *         so leaves read endpoints/tokens/signer from the registry and stay byte-identical across chains.
 *         Each chain deploys its own implementation with its own config.
 */
struct CounterfactualChainConfig {
    address signer;
    address spokePool;
    address wrappedNativeToken;
    /// @dev "Native" SpokePool route: the native sentinel where the deposit is `msg.value` (wrapped to
    ///      `wrappedNativeToken`), or an ERC-20 on chains with no native gas token. See `nativeToken()`.
    address nativeToken;
    address cctpSrcPeriphery;
    address cctpTokenMessenger;
    uint32 cctpSourceDomain;
    /// @dev Single-token OFT periphery (USDT0). The OFT leaf picks the periphery by its getter selector, so
    ///      another OFT token is a beacon upgrade adding another getter.
    address oftSrcPeriphery;
    uint32 oftSrcEid;
    address usdc;
    address usdt;
}

/**
 * @title CounterfactualBeacon
 * @notice Per-chain registry and **beacon** for every counterfactual `BeaconProxy`. Holds the
 *         `implementation` all proxies run, the `upgradeRoot` authorizing per-proxy root updates, and the
 *         chain config (endpoints, domains/EIDs, fee signer, tokens) that leaves read under delegatecall.
 * @dev A UUPS proxy, so its address is permanent (anchoring every `BeaconProxy`) while its logic evolves.
 *      `implementation`/`upgradeRoot` are mutable storage; the chain config is `public immutable` (in code,
 *      readable through the proxy), so changing a value or adding a token is a UUPS upgrade. For an
 *      identical proxy address across chains, deploy against a uniform bootstrap then `upgradeToAndCall` to
 *      the chain-specific implementation. `Ownable2Step` admin (no timelock) — it can retarget every proxy
 *      instantly, so use a trusted multisig. `implementation()` is the beacon target, not the registry's
 *      own UUPS implementation.
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
    address public immutable nativeToken;
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
        nativeToken = config.nativeToken;
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
     * @notice Initialize the registry's mutable storage (chain config comes from the constructor).
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
