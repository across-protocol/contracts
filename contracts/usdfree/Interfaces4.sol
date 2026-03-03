// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

struct Step {
    address executor;
    bytes message;
}

struct MerkleOrder {
    bytes32 salt;
    bytes32 root;
}

struct SubOrder {
    Step cur;
    bytes next;
}

struct TokenAmount {
    address token;
    uint256 amount;
}

struct SubmitterData {
    TokenAmount[] extraFunding;
    bytes executorMessage;
}

struct TypedData {
    uint8 typ;
    bytes data;
}

interface IOrderGateway {
    function submit(
        MerkleOrder calldata merkleOrder,
        SubOrder calldata selectedOrder,
        bytes[] calldata selectedProof,
        TypedData calldata orderFunding, // by the user
        SubmitterData calldata submitterData
    ) external payable;
}

interface IExecutor {
    function execute(
        bytes32 orderId,
        TokenAmount calldata orderIn,
        SubOrder calldata order,
        address submitter,
        bytes calldata submitterMessage
    ) external payable; // onlyAuthorizedCaller (OrderStore / OrderGateway)
}

interface IUserActionExecutor {
    function executeAndForward(
        bytes32 orderId,
        TokenAmount calldata amountIn,
        bytes calldata message,
        TypedData calldata next
    ) external payable;
}
