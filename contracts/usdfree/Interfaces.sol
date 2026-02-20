// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

enum GenericStepType {
    AuctionSubmitterUser,
    SubmitterUser,
    User
}

enum TokenRequirementType {
    StrictAmount,
    MinAmount
}

enum StaticRequirementType {
    Submitter,
    Deadline,
    ExternalStaticCall
}

enum SubmitterActionType {
    None,
    MulticallHandler,
    Weiroll // Reserved for future support.
}

enum TransferType {
    Approval,
    Transfer,
    Permit2Approval // Reserved for future support.
}

enum AuctionType {
    Offchain,
    DutchOnchain // Reserved for future support.
}

enum ContinuationType {
    GenericSteps,
    StepAndNextHash,
    StepAndNextData
}

struct TypedData {
    uint8 typ;
    bytes data;
}

// `parts` encoding:
// - AuctionSubmitterUser: [abi.encode(AuctionAction), abi.encode(UserRequirementsAndAction)]
// - SubmitterUser: [abi.encode(UserRequirementsAndAction)]
// - User: [abi.encode(UserRequirementsAndAction)]
struct GenericStep {
    GenericStepType typ;
    bytes[] parts;
}

// User-provided auction instruction. Submitter-provided auction resolution data is separate.
struct AuctionAction {
    AuctionType typ;
    bytes data;
}

struct UserRequirementsAndAction {
    // token requirement encoded as (typ, data)
    TypedData tokenReq;
    // static requirements encoded as (typ, data)
    TypedData[] staticReqs;
    // user action executor target for this step
    address target;
    // transfer strategy encoded as (typ, data)
    TypedData transfer;
    // params for execution on `target`.
    bytes userAction;
    address refundRecipient;
}

struct AmountTokenRequirement {
    address token;
    uint256 amount;
}

struct SubmitterRequirement {
    address submitter;
}

struct DeadlineRequirement {
    uint256 deadline;
}

struct ExternalStaticCallRequirement {
    address target;
    bytes data;
    bytes32 expectedResultHash; // 0 disables return-data hash check.
}

struct SubmitterActions {
    SubmitterActionType typ;
    bytes data;
}

struct ExecutorCall {
    address target;
    bytes callData;
    uint256 value;
}

struct OffchainAuctionConfig {
    address authority;
    uint256 deadline;
}

struct RequirementChange {
    uint8 stepOffset;
    uint8 reqId;
    bytes change;
}

struct AuctionResolution {
    RequirementChange[] changes;
    bytes sig;
}

struct Continuation {
    ContinuationType typ;
    // GenericSteps: abi.encode(GenericStep[])
    // StepAndNextHash: abi.encode(bytes32)
    // StepAndNextData: abi.encode(StepAndNext)
    bytes data;
}

struct MerkleOrder {
    bytes32 salt;
    bytes32 routesRoot;
}

struct TokenAmount {
    address token;
    uint256 amount;
}

// Represents one explicit execution chunk. `nextContinuation` recursively carries the rest.
struct StepAndNext {
    GenericStep curStep;
    bytes nextContinuation;
}

struct MerkleRoute {
    StepAndNext stepAndNext;
    bytes32[] proof;
}

struct SubmitterData {
    // token == address(0) means native token funding from submitter.
    TokenAmount[] extraFunding;
    // Step-specific submitter data consumed by executor substeps.
    bytes[] parts;
}

interface IOrderGateway {
    function submit(
        MerkleOrder calldata order,
        MerkleRoute calldata route,
        bytes calldata funding,
        SubmitterData calldata submitterData
    ) external payable;
}

interface IExecutor {
    function execute(
        address submitter,
        bytes32 orderId,
        address userTokenIn,
        uint256 userAmountIn,
        uint256 submitterNativeAmount,
        bytes[] calldata submitterParts,
        StepAndNext calldata stepAndNext
    ) external payable;
}

interface IUserActionExecutor {
    function execute(
        address token,
        uint256 amount,
        bytes32 orderId,
        bytes calldata actionParams,
        bytes calldata nextContinuation
    ) external payable;
}

interface IOrderStore {
    function handle(address token, uint256 amount, bytes32 orderId, bytes calldata continuation) external payable;

    function handleAtomic(
        address token,
        uint256 amount,
        bytes32 orderId,
        bytes calldata continuation,
        address submitter,
        SubmitterData calldata submitterData
    ) external payable;

    function fill(uint256 localOrderIndex, SubmitterData calldata submitterData) external payable;
}
