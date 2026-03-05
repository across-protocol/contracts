// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { MerkleProof } from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { IERC1271 } from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import { ICounterfactualImplementation } from "../../interfaces/ICounterfactualImplementation.sol";
import { ICounterfactualDeposit } from "../../interfaces/ICounterfactualDeposit.sol";

/**
 * @title CounterfactualDeposit
 * @notice Merkle-dispatched entrypoint for counterfactual deposit clones. All clones are instances of this contract.
 * @dev The clone's immutable args are (merkleRoot, signer). Each merkle leaf is
 *      `keccak256(abi.encode(implementation, keccak256(params)))`. Callers prove leaf inclusion, then the
 *      dispatcher delegatecalls the implementation. The signer enables EIP-1271 signature validation
 *      for SpokePool speed-up deposits where the clone is the depositor.
 *
 *      Call chain: Caller → CALL → Clone (EIP-1167 proxy) → DELEGATECALL → Dispatcher → DELEGATECALL → Implementation
 *      - address(this) = clone address throughout (correct for EIP-712, token balances)
 *      - msg.sender = original caller throughout
 *      - msg.value = original value throughout
 */
contract CounterfactualDeposit is ICounterfactualDeposit, IERC1271 {
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
        (bytes32 merkleRoot, ) = abi.decode(Clones.fetchCloneArgs(address(this)), (bytes32, address));

        bytes32 leaf = keccak256(abi.encode(implementation, keccak256(params)));

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

    /**
     * @notice EIP-1271 signature validation. Validates that the signature was produced by the clone's
     *         authorized signer, enabling SpokePool speed-up deposits where the clone is the depositor.
     * @param hash The hash that was signed.
     * @param signature The signature to validate against the clone's signer.
     * @return magicValue `IERC1271.isValidSignature.selector` if valid, `0xffffffff` otherwise.
     */
    function isValidSignature(bytes32 hash, bytes memory signature) external view returns (bytes4 magicValue) {
        (, address signer) = abi.decode(Clones.fetchCloneArgs(address(this)), (bytes32, address));
        return ECDSA.recover(hash, signature) == signer ? this.isValidSignature.selector : bytes4(0xffffffff);
    }
}
