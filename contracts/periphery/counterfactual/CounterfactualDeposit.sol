// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { MerkleProof } from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import { ICounterfactualBeacon } from "../../interfaces/ICounterfactualBeacon.sol";
import { ICounterfactualDeposit } from "../../interfaces/ICounterfactualDeposit.sol";
import { ICounterfactualImplementation } from "../../interfaces/ICounterfactualImplementation.sol";

/**
 * @title CounterfactualDeposit
 * @notice The counterfactual implementation — the merkle-dispatched entry point every counterfactual
 *         `BeaconProxy` runs (the registry/beacon's `implementation()`). It also owns the proxy's
 *         mutable state: `activeRoot` (the route tree), held in an ERC-7201 namespaced slot. Verifies a
 *         leaf against `activeRoot`, then delegatecalls the per-bridge implementation the leaf authorizes
 *         (which decodes the destination identity from `params` and bridges).
 * @dev Resolved live from the beacon (`CounterfactualBeacon.implementation()`) on every call, so all proxies
 *      always run the current implementation — there is no per-proxy upgrade and no bootstrap. Runs
 *      under the proxy's delegatecall, so `address(this)` is the proxy (correct for EIP-712 domains and
 *      token balances), `msg.sender` is the original caller, `msg.value` the original value.
 *
 *      The implementation is upgraded **globally** by the admin setting the beacon's `implementation`;
 *      only the per-proxy `activeRoot` is mutable here, via the permissionless `updateRoot` (proven
 *      against the registry's `(proxy, latestRoot)` tree). Root updates are **best-effort** — a proxy
 *      keeps its `activeRoot` until someone updates it; there is no on-chain version/min-version gate.
 *      **Every future implementation version MUST preserve this ERC-7201 storage layout.**
 *
 *      Note: every leaf implementation's fee signature binds the leaf's route via `routeParamsHash` (the
 *      EIP-712 typehash for all four — SpokePool, CCTP, VanillaCCTP, OFT — commits it). So a fee signature
 *      authored for one leaf cannot be replayed against another, and a clone's tree MAY safely contain
 *      multiple leaves that share an implementation address (e.g. two OFT routes for different input tokens
 *      to one destination identity). Cross-chain replay is independently prevented by the `chainId` in the
 *      EIP-712 domain, and cross-clone replay by `verifyingContract = address(this)`.
 * @custom:security-contact bugs@across.to
 */
contract CounterfactualDeposit is Initializable, ICounterfactualDeposit {
    /// @custom:storage-location erc7201:across.counterfactual.upgradeable.storage
    struct CounterfactualStorage {
        bytes32 activeRoot;
    }

    // keccak256(abi.encode(uint256(keccak256("across.counterfactual.upgradeable.storage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant STORAGE_LOCATION = 0x5b89d334b964a560e5498fb6b9c95b4213116f116bbd1e59c9c85ba952217700;

    /// @notice The `CounterfactualBeacon` — the beacon every counterfactual `BeaconProxy` resolves its
    ///         implementation from, and the source of the `upgradeRoot` used by `updateRoot`.
    ICounterfactualBeacon public immutable BEACON;

    /// @notice Emitted when `activeRoot` is updated via the upgrade tree.
    event RootUpdated(bytes32 newRoot);

    /// @dev Merkle proof against the registry's `(proxy, latestRoot)` tree failed.
    error InvalidUpgradeProof();
    /// @dev New root equals the current `activeRoot` (no-op).
    error RootUnchanged();

    constructor(ICounterfactualBeacon beacon) {
        BEACON = beacon;
        _disableInitializers();
    }

    /// @notice Initialize the proxy's `activeRoot` from `initialRoot`.
    /// @dev Delegatecalled once by the `BeaconProxy` constructor (its `data` carries `initialRoot`, which
    ///      thereby enters the CREATE2 preimage — binding the address to `initialRoot`).
    function initialize(bytes32 initialRoot) external initializer {
        _getStorage().activeRoot = initialRoot;
    }

    /// @dev Accept native value sent to the proxy (deposits before/after deployment, refunds).
    receive() external payable {}

    /// @notice The merkle root authorizing this proxy's deposit routes.
    function activeRoot() public view returns (bytes32) {
        return _getStorage().activeRoot;
    }

    /// @inheritdoc ICounterfactualDeposit
    function execute(
        address implementation,
        bytes calldata params,
        bytes calldata submitterData,
        bytes32[] calldata proof
    ) external payable {
        _execute(implementation, params, submitterData, proof);
    }

    /// @inheritdoc ICounterfactualDeposit
    function updateRootAndExecute(
        bytes32 newRoot,
        bytes32[] calldata updateProof,
        address implementation,
        bytes calldata params,
        bytes calldata submitterData,
        bytes32[] calldata executeProof
    ) external payable {
        // Skip the update (and its `RootUnchanged` revert) when the proxy is already current. NOTE:
        // `updateProof` is therefore NOT validated in that case — there is no root change to authorize.
        if (newRoot != activeRoot()) _updateRoot(newRoot, updateProof);
        _execute(implementation, params, submitterData, executeProof);
    }

    /// @notice Update `activeRoot`, proving `(address(this), newRoot)` is in the registry's upgrade tree.
    /// @dev Permissionless. Root updates are best-effort — a proxy keeps its `activeRoot` until updated.
    function updateRoot(bytes32 newRoot, bytes32[] calldata proof) external {
        _updateRoot(newRoot, proof);
    }

    function _execute(
        address implementation,
        bytes calldata params,
        bytes calldata submitterData,
        bytes32[] calldata proof
    ) private {
        // Double-hash to prevent leaf/internal-node ambiguity (OpenZeppelin standard).
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(implementation, keccak256(params)))));
        if (!MerkleProof.verify(proof, activeRoot(), leaf)) revert InvalidProof();

        (bool success, bytes memory result) = implementation.delegatecall(
            abi.encodeCall(ICounterfactualImplementation.execute, (params, submitterData))
        );
        if (!success) {
            assembly {
                revert(add(result, 32), mload(result))
            }
        }
    }

    function _updateRoot(bytes32 newRoot, bytes32[] calldata proof) private {
        CounterfactualStorage storage $ = _getStorage();
        if (newRoot == $.activeRoot) revert RootUnchanged();
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(address(this), newRoot))));
        if (!MerkleProof.verify(proof, BEACON.upgradeRoot(), leaf)) revert InvalidUpgradeProof();
        $.activeRoot = newRoot;
        emit RootUpdated(newRoot);
    }

    function _getStorage() private pure returns (CounterfactualStorage storage $) {
        assembly {
            $.slot := STORAGE_LOCATION
        }
    }
}
