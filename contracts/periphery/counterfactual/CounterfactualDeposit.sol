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
    /// @notice Address of the migration registry consulted by `migrate`. Same address on every chain.
    address public immutable migrationRegistry;

    /// @notice The clone's current merkle root. A non-zero value also serves as the initialized sentinel.
    bytes32 public merkleRoot;

    constructor(address _migrationRegistry) {
        migrationRegistry = _migrationRegistry;
    }

    /// @dev Accept native ETH sent to the clone (e.g. user deposits or refunds).
    receive() external payable {}

    /// @inheritdoc ICounterfactualDeposit
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
