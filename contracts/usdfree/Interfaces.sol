// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

struct Step {
    address executor;
    bytes message;
}

struct Path {
    Step cur;
    bytes next;
}

// Note: Order is a Merkle tree of Paths
struct Order {
    bytes32 root;
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

enum OrderFundingType {
    Approval,
    Permit2,
    TransferWithAuthorization
}

struct ApprovalFunding {
    TokenAmount tokenAmount;
    bytes32 salt;
}

struct Permit2Funding {
    address signer;
    TokenAmount tokenAmount;
    uint256 nonce;
    uint256 deadline;
    bytes signature;
}

struct AuthorizationFunding {
    address signer;
    TokenAmount tokenAmount;
    uint256 validAfter;
    uint256 validBefore;
    bytes signature;
    bytes32 salt;
}

interface IOrderGateway {
    // Note: submit `Order`. If submitterData is a requirement, the `Order` will be stored instead and wait for a submitter
    function submit(
        Order calldata order,
        Path calldata selectedPath,
        bytes32[] calldata pathProof,
        TypedData calldata orderFunding
    ) external payable; // nonReentrant

    // Note: this entrypoint has `submitterData` and therefore should always be able to atomically execute a `Step`
    function submitWithData(
        Order calldata order,
        Path calldata selectedPath,
        bytes32[] calldata pathProof,
        TypedData calldata orderFunding,
        SubmitterData calldata submitterData
    ) external payable; // nonReentrant

    function fill(bytes32 orderId, SubmitterData calldata submitterData) external payable;
}

interface IExecutor {
    function execute(
        bytes32 orderId,
        TokenAmount calldata orderIn,
        Path calldata path,
        address submitter,
        bytes calldata submitterData
    ) external payable; // onlyAuthorizedCaller (OrderStore / OrderGateway)
}

interface IUserActionExecutor {
    function executeAndForward(
        bytes32 orderId,
        TokenAmount calldata amountIn,
        bytes calldata message,
        bytes calldata next
    ) external payable;
}
