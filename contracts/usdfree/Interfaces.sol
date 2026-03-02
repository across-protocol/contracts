// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

enum GenericStepType {
    AuctionSubmitterUser,
    SubmitterUser,
    User
}

enum TokenRequirementType {
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
    // Reserved for future support.
    Weiroll
}

enum UserDataType {
    RequirementsAndActionV1,
    RequirementsAndSendV1
}

enum AuctionType {
    Offchain,
    // Reserved for future support.
    DutchOnchain,
    HybridOffchainDutch
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

struct ForwardingAmounts {
    uint256 erc20Amount;
    uint256 nativeAmount;
}

// `userData` encoding:
// - UserDataType.RequirementsAndActionV1: abi.encode(UserRequirementsAndAction)
// - UserDataType.RequirementsAndSendV1: abi.encode(UserRequirementsAndSend)
// `parts` encoding:
// - AuctionSubmitterUser: [abi.encode(RequirementModifierAction)]
// - SubmitterUser: []
// - User: []
// submitter `parts` encoding:
// - AuctionSubmitterUser: [if Offchain: abi.encode(AuctionResolution), abi.encode(SubmitterActions), optional abi.encode(ForwardingAmounts)]
// - SubmitterUser: [abi.encode(SubmitterActions), optional abi.encode(ForwardingAmounts)]
// - User: []
struct GenericStep {
    GenericStepType typ;
    RefundConfig refundConfig;
    TypedData userData;
    bytes[] parts;
}

// User-provided requirement-modifier config. Submitter-provided resolution data is separate.
struct RequirementModifierAction {
    AuctionType typ;
    bytes data;
}

struct UserRequirements {
    // token requirement encoded as (typ, data)
    TypedData tokenReq;
    // static requirements encoded as (typ, data)
    TypedData[] staticReqs;
    // user defaults; submitter may override via submitter `parts`.
    ForwardingAmounts forwarding;
}

struct UserRequirementsAndAction {
    UserRequirements reqs;
    // user action executor target for this step.
    address target;
    // params for execution on `target`.
    bytes userAction;
}

struct UserRequirementsAndSend {
    UserRequirements reqs;
    // recipient for direct transfer.
    address recipient;
}

struct AmountTokenRequirement {
    address token;
    uint256 amount;
}

struct SubmitterRequirement {
    address submitter;
    uint256 exclusivityDeadline;
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
    uint8 reqId;
    bytes change;
}

struct AuctionResolution {
    RequirementChange[] changes;
    bytes sig;
}

struct RefundConfig {
    address refundRecipient;
    uint256 reverseDeadline;
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
    // Additional ERC20 funding pulled from submitter and sent to executor.
    TokenAmount[] extraErc20Funding;
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

    function refundByUser(uint256 localOrderIndex) external;

    function refundByAdmin(uint256 localOrderIndex) external;
}
