// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { MerkleProof } from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import { ICounterfactualImplementation } from "../../interfaces/ICounterfactualImplementation.sol";
import { ICounterfactualDeposit } from "../../interfaces/ICounterfactualDeposit.sol";

/**
 * @title CounterfactualDeposit
 * @notice Merkle-dispatched entrypoint for counterfactual deposit clones. All clones are instances of this contract.
 * @dev The clone's immutable arg is a merkle root. Each leaf is `keccak256(bytes.concat(keccak256(abi.encode(implementation, keccak256(params)))))`.
 *      Callers prove leaf inclusion, then the dispatcher delegatecalls the implementation.
 *
 *      Call chain: Caller → CALL → Clone (EIP-1167 proxy) → DELEGATECALL → Dispatcher → DELEGATECALL → Implementation
 *      - address(this) = clone address throughout (correct for EIP-712, token balances)
 *      - msg.sender = original caller throughout
 *      - msg.value = original value throughout
 *
 *      Note: Some implementations — such as CounterfactualDepositSpokePool — use authorization signatures
 *      that cover execution-time parameters (amounts, deadlines, etc.) but do not commit to the leaf's
 *      route-specific `params` (destination chain, tokens, recipient, etc.). If two leaves share the same
 *      implementation address, a caller could prove leaf A's route params while submitting an authorization
 *      signature intended for leaf B's route, since the signature is valid for either leaf. The system is
 *      intended to be used such that a clone's merkle tree never contains multiple leaves with the same
 *      implementation address.
 */
contract CounterfactualDeposit is ICounterfactualDeposit {
    /// @dev Accept native ETH sent to the clone (e.g. user deposits or refunds).
    receive() external payable {}

    /**
     * @notice Execute an implementation by proving its inclusion in the clone's merkle tree.
     * @param implementation The implementation contract to delegatecall.
     * @param params ABI-encoded route parameters (hashed into the merkle leaf).
     * @param submitterData ABI-encoded data supplied by the caller at execution time.
     * @param proof Merkle proof for the (implementation, keccak256(params)) leaf.
     */
    function execute(
        address implementation,
        bytes calldata params,
        bytes calldata submitterData,
        bytes32[] calldata proof
    ) external payable {
        bytes32 merkleRoot = abi.decode(Clones.fetchCloneArgs(address(this)), (bytes32));

        // Double-hash to prevent leaf/internal-node ambiguity (OpenZeppelin standard).
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(implementation, keccak256(params)))));

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
