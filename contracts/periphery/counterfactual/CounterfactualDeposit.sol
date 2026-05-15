// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { MerkleProof } from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import { ICounterfactualImplementation } from "../../interfaces/ICounterfactualImplementation.sol";
import { ICounterfactualDeposit } from "../../interfaces/ICounterfactualDeposit.sol";

/**
 * @title CounterfactualDeposit
 * @notice Merkle-dispatched entrypoint for counterfactual deposit clones. All clones are instances of this contract.
 * @dev The clone's immutable arg is a merkle root. Each leaf is
 *      `keccak256(bytes.concat(keccak256(abi.encode(block.chainid, implementation, keccak256(params)))))`.
 *      The dispatcher folds `block.chainid` into the leaf preimage so the same merkle root can authorize
 *      different `(implementation, params)` tuples on different chains. The off-chain tree enumerates one
 *      leaf per `(srcChainId, implementation, params)` triple; because the tree is identical on every chain,
 *      the clone CREATE2 address is identical on every chain. A chain-A leaf cannot be replayed on chain B
 *      because the dispatcher rebuilds the leaf with the chain's own `block.chainid`.
 *
 *      Callers prove leaf inclusion, then the dispatcher delegatecalls the implementation.
 *
 *      Call chain: Caller → CALL → Clone (EIP-1167 proxy) → DELEGATECALL → Dispatcher → DELEGATECALL → Implementation
 *      - address(this) = clone address throughout (correct for EIP-712, token balances)
 *      - msg.sender = original caller throughout
 *      - msg.value = original value throughout
 *
 *      Implementations whose authorization signatures cover only execution-time parameters (e.g. amounts,
 *      deadlines) must additionally commit to `keccak256(params)` in their signed payload so that a caller
 *      cannot prove leaf A's params while submitting a signature issued for leaf B's route. See
 *      `CounterfactualDepositSpokePool` for the canonical example.
 */
contract CounterfactualDeposit is ICounterfactualDeposit {
    /// @dev Accept native ETH sent to the clone (e.g. user deposits or refunds).
    receive() external payable {}

    /**
     * @notice Execute an implementation by proving its inclusion in the clone's merkle tree.
     * @param implementation The implementation contract to delegatecall.
     * @param params ABI-encoded route parameters (hashed into the merkle leaf).
     * @param submitterData ABI-encoded data supplied by the caller at execution time.
     * @param proof Merkle proof for the (block.chainid, implementation, keccak256(params)) leaf.
     */
    function execute(
        address implementation,
        bytes calldata params,
        bytes calldata submitterData,
        bytes32[] calldata proof
    ) external payable {
        bytes32 merkleRoot = abi.decode(Clones.fetchCloneArgs(address(this)), (bytes32));

        // `block.chainid` is folded in (not caller-supplied) so chain-A leaves cannot be replayed on chain B.
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
}
