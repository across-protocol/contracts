// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { MerkleProof } from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import { ICounterfactualImplementation } from "../../interfaces/ICounterfactualImplementation.sol";
import { ICounterfactualDeposit } from "../../interfaces/ICounterfactualDeposit.sol";
import { ICounterfactualMigrationRegistry } from "../../interfaces/ICounterfactualMigrationRegistry.sol";

/**
 * @title CounterfactualDeposit
 * @notice Merkle-dispatched entrypoint for counterfactual deposit clones. All clones are instances of
 *         this contract via EIP-1167 minimal proxies.
 * @dev Cross-chain identity model:
 *      - `identityHash = keccak256(abi.encode(recipient, dstChainId, outputToken))` is folded into
 *        the CREATE2 salt at the factory (`salt = keccak256(abi.encode(identityHash, initialRoot))`),
 *        so the clone address is the same on every EVM chain for the same `(identity, initialRoot)`
 *        pair. The clone has no immutable args — `address(this)` itself uniquely identifies the clone
 *        and is what the migrate meta-leaf is keyed on.
 *      - The clone's merkle root lives in storage (`merkleRoot`) and can be rotated via `migrate`
 *        without changing the clone's address.
 *
 *      Leaf preimage:
 *          leaf = keccak256(bytes.concat(keccak256(abi.encode(block.chainid, implementation, keccak256(params)))))
 *      The same operational root is valid across every source chain: enumeration includes `block.chainid`
 *      in every leaf, so on chain X only leaves with `chainId == X` are provable.
 *
 *      Call chain: Caller → CALL → Clone (EIP-1167 proxy) → DELEGATECALL → Dispatcher → DELEGATECALL → Implementation
 *      - `address(this)` = clone address throughout (correct for EIP-712, token balances)
 *      - `msg.sender` = original caller throughout
 *      - `msg.value` = original value throughout
 *
 *      Replay protection for `migrate` comes from the registry holding the latest metaRoot only — when
 *      admin rotates `metaRoot`, every proof against the previous value stops verifying. A no-op
 *      migration (newRoot equals current merkleRoot) reverts with `NoOpMigration` to prevent
 *      grief and event spam.
 *
 *      Note: some implementations — such as `CounterfactualDepositSpokePool` — use authorization
 *      signatures that cover execution-time parameters. Each impl's typehash binds `paramsHash` so
 *      cross-leaf signature replay (between two leaves on the same impl) is prevented even when
 *      multiple leaves share an implementation address.
 * @custom:security-contact bugs@across.to
 */
contract CounterfactualDeposit is ICounterfactualDeposit {
    /// @dev Sentinel value written to the dispatcher's own storage in the constructor so that
    ///      direct `initialize` calls on the dispatcher (rather than via a clone) revert with
    ///      `AlreadyInitialized`, and direct `execute` calls find no provable leaf (`leaf` would
    ///      have to hash to this value, which is cryptographically infeasible). Each clone has
    ///      its own storage starting at zero, so this lock does not affect clones.
    bytes32 private constant IMPLEMENTATION_LOCK = bytes32(uint256(1));

    /// @dev Thrown when a critical address argument is the zero address.
    error ZeroAddress();

    /// @notice Address of the migration registry consulted by `migrate`. Same address on every chain.
    address public immutable migrationRegistry;

    /// @notice The clone's current merkle root. A non-zero value also serves as the initialized sentinel.
    bytes32 public merkleRoot;

    constructor(address _migrationRegistry) {
        if (_migrationRegistry == address(0)) revert ZeroAddress();
        migrationRegistry = _migrationRegistry;
        // Lock the dispatcher's own storage: makes the dispatcher itself non-executable while
        // leaving clones' separate storage untouched (they delegatecall, so writes target the
        // clone's storage, not the dispatcher's).
        merkleRoot = IMPLEMENTATION_LOCK;
    }

    /// @dev Accept native ETH sent to the clone (e.g. user deposits or refunds).
    receive() external payable {}

    /**
     * @inheritdoc ICounterfactualDeposit
     * @dev `initialize` is permissionless by design. Safety relies on three properties:
     *      1. The clone's CREATE2 address is a function of `(factory, salt = keccak256(identityHash, initialRoot), dispatcher)`,
     *         so only the factory can deploy a clone at the predicted address. The factory calls
     *         `initialize` atomically in the same tx as the CREATE2 — no window for anyone else
     *         to slip in.
     *      2. The `merkleRoot != 0` guard rejects any subsequent `initialize` call on the same
     *         clone.
     *      3. The dispatcher's own storage has `merkleRoot` locked to `IMPLEMENTATION_LOCK` in its
     *         constructor (see above), so direct calls to the dispatcher hit `AlreadyInitialized`.
     *      Together these prevent a third party from installing a different `initialRoot` into a
     *      clone or initializing the dispatcher contract itself.
     */
    function initialize(bytes32 initialRoot) external {
        if (merkleRoot != bytes32(0)) revert AlreadyInitialized();
        if (initialRoot == bytes32(0)) revert InvalidInitialRoot();
        merkleRoot = initialRoot;
        emit Initialized(initialRoot);
    }

    /// @inheritdoc ICounterfactualDeposit
    function execute(
        address implementation,
        bytes calldata params,
        bytes calldata submitterData,
        bytes32[] calldata proof
    ) external payable {
        // Double-hash to prevent leaf/internal-node ambiguity (OpenZeppelin standard).
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(block.chainid, implementation, keccak256(params)))));

        if (!MerkleProof.verify(proof, merkleRoot, leaf)) revert InvalidProof();

        (bool success, bytes memory result) = implementation.delegatecall(
            abi.encodeCall(ICounterfactualImplementation.execute, (params, submitterData))
        );
        if (!success) {
            assembly {
                revert(add(result, 32), mload(result))
            }
        }
    }

    /// @inheritdoc ICounterfactualDeposit
    function migrate(bytes32 newRoot, bytes32[] calldata metaProof) external {
        if (newRoot == merkleRoot) revert NoOpMigration();

        bytes32 metaLeaf = keccak256(bytes.concat(keccak256(abi.encode(address(this), newRoot))));
        bytes32 metaRoot = ICounterfactualMigrationRegistry(migrationRegistry).metaRoot();

        if (!MerkleProof.verify(metaProof, metaRoot, metaLeaf)) revert InvalidMetaProof();

        merkleRoot = newRoot;
        emit Migrated(newRoot);
    }
}
