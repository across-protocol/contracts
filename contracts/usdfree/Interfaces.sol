// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

struct TypedData {
    uint8 typ;
    bytes data;
}

struct Step {
    // Note: used for obfuscation of Merkle leaves
    bytes32 salt;
    address executor;
    // Note: interpreted by executor
    bytes message;
}

struct RefundSettings {
    address recipient;
    uint256 deadline; // claim is possible _after_ deadline
}

struct Funding {
    TypedData[] funding; // type + data. Data includes amounts, per-type structs and signatures if needed for gasless
}

struct Order {
    // Note: used for enforcing orderId uniqueness when necessary (i.e. help an offchain actor maintain orderId => sponsorshipRebate mapping).
    // If nonce == 0, orderId uniqueness is not enforced by the contract, which saves us SLOAD + SSTORE operations
    bytes32 nonce;
    // Note: used for orderId namespacing. Can let orderOwner use nonces for certain commitments
    address orderOwner;
    // Note: Merkle root that has Steps and RefundSettings as leaves
    bytes32 root;
}

struct SubmitterInputs {
    Step step;
    // Note: proof that step is a part of order.root Merkle tree
    bytes32[] proof;
    // Note: submitter funding, that commits to a different (more broad) witness
    Funding funding;
    // Note: when interpreting step.message provided by the user, step.executor will sometimes reach into executorMessage
    // provided here for submitter-provided data. User defines commands + static values, this lets submitter augment
    // execution with dynamic data (e.g. auction resolution or DEX swap instructions)
    bytes executorMessage;
}

interface IOrderGateway {
    function submit(
        Order calldata order,
        // Note: Gateway has to check that orderOwnerFunding only pulls funds from order.orderOwner. orderOwner is used for orderId namespacing
        Funding calldata orderOwnerFunding,
        SubmitterInputs calldata submitterInputs
    ) external payable;
}

library USDFreeIdLib {
    // TODO: this will come from a EIP-712 lib
    function domainHash(uint32 chainId, address contractAddr) internal pure returns (bytes32) {
        return keccak256(abi.encode("USDFree.Domain.V1", chainId, contractAddr));
    }

    function orderId(bytes32 domainH, Order calldata order) internal pure returns (bytes32) {
        return keccak256(abi.encode("USDFreeIdLib.OrderId.V1", domainH, order.nonce, order.orderOwner, order.root));
    }

    // Note: called only when there's a merkle tree proof is presented. Otherwise, orderId is enough for the purposese of emitting a unique order execution path
    function stepId(bytes32 orderId_, Step calldata step) internal pure returns (bytes32) {
        return
            keccak256(
                abi.encode("USDFreeIdLib.StepId.V1", orderId_, step.salt, step.executor, keccak256(step.message))
            );
    }

    // Note: used as witness for submitter gasless funding, if any
    function executionId(
        bytes32 orderId_,
        bytes32 stepId_,
        SubmitterInputs calldata submitterInputs
    ) internal pure returns (bytes32) {
        return
            keccak256(
                // TODO: submitterSalt might be useful for varying submitter witness(==TWA nonce), similar to order.nonce?
                abi.encode(
                    "USDFreeIdLib.ExecutionId.V1",
                    orderId_, // commit to user order
                    stepId_, // commit to a specific step being executed
                    keccak256(submitterInputs.executorMessage) // commit to own instructions provided
                )
            );
    }
}
