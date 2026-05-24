// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { OwnableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { IRoutePolicy } from "../../interfaces/IRoutePolicy.sol";

/**
 * @title RoutePolicy
 * @notice UUPS-upgradeable, `Ownable` contract holding one merkle root that enumerates the routes a
 *         set of counterfactual clones may execute on this chain. The owner (typically a multisig)
 *         calls `updateRoot(newRoot)` to swap the route set globally for every clone bound to this
 *         policy, and `upgradeToAndCall(newImpl, data)` to evolve the implementation (e.g. to add
 *         per-clone overrides) without changing the policy's address.
 * @dev The proxy address is intended to be identical across every EVM chain — deploy the
 *      implementation and `ERC1967Proxy` via the deterministic-deployment proxy with constant
 *      init data (`initialize(deployerEOA, bytes32(0))`), then transfer ownership to the chain-local
 *      multisig as a post-deploy step. Each chain maintains its own independent root storage.
 *
 *      Storage uses the ERC-7201 namespaced layout so future implementations can extend the storage
 *      struct (e.g. add a per-clone override mapping) without colliding with prior fields.
 * @custom:security-contact bugs@across.to
 */
contract RoutePolicy is IRoutePolicy, Initializable, OwnableUpgradeable, UUPSUpgradeable {
    /// @custom:storage-location erc7201:counterfactual.routepolicy.storage
    struct RoutePolicyStorage {
        bytes32 root;
    }

    // keccak256(abi.encode(uint256(keccak256("counterfactual.routepolicy.storage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant ROUTE_POLICY_STORAGE_LOCATION =
        0x2f3e4afa926da5c30a31c09927ced25bd5c39db7e35f8f0f74dfb9d685f33300;

    /// @notice Emitted on every successful root update.
    event RootUpdated(bytes32 newRoot);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice One-time initializer for the proxy. Sets the initial owner and root.
     * @param initialOwner The address that will own the proxy. Typically the deployer EOA at deploy
     *                     time, transferred to the chain-local multisig as a post-deploy step.
     * @param initialRoot  The starting `activeRoot` value. `bytes32(0)` is valid and effectively
     *                     disables all non-admin routes until the owner calls `updateRoot`.
     */
    function initialize(address initialOwner, bytes32 initialRoot) external initializer {
        __Ownable_init(initialOwner);
        _getStorage().root = initialRoot;
    }

    /**
     * @inheritdoc IRoutePolicy
     * @dev The `clone` argument is unused in this implementation — a single root authorizes every
     *      clone bound to this policy. Future implementations can use it to vary the root per-clone
     *      without changing the interface.
     */
    function activeRoot(address /* clone */) external view returns (bytes32) {
        return _getStorage().root;
    }

    /// @notice Replace the active root. Restricted to the policy owner.
    function updateRoot(bytes32 newRoot) external onlyOwner {
        _getStorage().root = newRoot;
        emit RootUpdated(newRoot);
    }

    /// @dev Required by UUPS — only the owner can upgrade the implementation.
    function _authorizeUpgrade(address) internal override onlyOwner {}

    function _getStorage() private pure returns (RoutePolicyStorage storage $) {
        assembly {
            $.slot := ROUTE_POLICY_STORAGE_LOCATION
        }
    }
}
