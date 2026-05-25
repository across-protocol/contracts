// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { OwnableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { IRoutePolicy } from "../../interfaces/IRoutePolicy.sol";

/**
 * @title RoutePolicyImmutableRoot
 * @notice UUPS-upgradeable `IRoutePolicy` implementation that bakes the active merkle root into an
 *         `immutable` of the implementation contract. The proxy holds ownership and upgrade
 *         authority; the root itself never lives in storage. Reads cost a single bytecode constant
 *         load instead of an `SLOAD`.
 *
 *         "Updating the root" is a UUPS upgrade: the owner deploys a new implementation with the
 *         new root in its constructor and calls `upgradeToAndCall(newImpl, "")` on the proxy. The
 *         proxy's address is unchanged across rotations; only its ERC-1967 implementation slot
 *         moves. Off-chain indexers can watch the standard `Upgraded(address)` event and read
 *         `activeRoot(...)` to learn the new root.
 * @dev The implementation contract is intended to be deployed behind an `ERC1967Proxy`. The
 *      implementation's constructor disables initializers on the implementation itself; the proxy
 *      is initialized exactly once via `initialize(initialOwner)`. Both the implementation and the
 *      proxy can be deployed deterministically (e.g. via the deterministic-deployment proxy) — on
 *      day 0 every chain deploys with the same `initialRoot` (typically `bytes32(0)`), so impl and
 *      proxy land at the same address everywhere. Subsequent per-chain rotations diverge: each
 *      chain deploys its own implementation carrying that chain's root, and upgrades its proxy.
 *      The proxy address stays constant on each chain throughout all rotations.
 * @custom:security-contact bugs@across.to
 */
contract RoutePolicyImmutableRoot is IRoutePolicy, Initializable, OwnableUpgradeable, UUPSUpgradeable {
    /// @notice Merkle root authorizing routes for every clone bound to this policy. Baked into
    ///         the implementation's runtime bytecode at construction time.
    bytes32 private immutable _root;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(bytes32 initialRoot) {
        _root = initialRoot;
        _disableInitializers();
    }

    /**
     * @notice One-time initializer for the proxy. Sets the initial owner. The root is fixed by the
     *         implementation's constructor and is not initialized here.
     * @param initialOwner The address that will own the proxy. Typically the deployer EOA at deploy
     *                     time, transferred to the chain-local multisig as a post-deploy step.
     */
    function initialize(address initialOwner) external initializer {
        __Ownable_init(initialOwner);
    }

    /**
     * @inheritdoc IRoutePolicy
     * @dev The `clone` argument is unused in this implementation — a single root authorizes every
     *      clone bound to this policy. Returns the implementation's immutable `_root`.
     */
    function activeRoot(address /* clone */) external view returns (bytes32) {
        return _root;
    }

    /// @dev Required by UUPS — only the owner can upgrade the implementation. Upgrading is the
    ///      mechanism by which the active root changes: the owner deploys a new implementation
    ///      carrying the new root and points the proxy at it.
    function _authorizeUpgrade(address) internal override onlyOwner {}
}
