// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

struct TypedData {
    uint8 typ;
    bytes data;
}

// Defines sequence of substeps performed as a part of that step
enum StepType {
    AuctionSubmitterUser,
    SubmitterUser,
    User
}

struct RefundSettings {
    bytes32 refundRecipient;
    uint256 reverseDeadline;
}

enum AuctionSubstepType {
    Offchain,
    DutchOnchain,
    OffchainWithDutchOnchainFallback
}

enum UserSubstepType {
    ReqPlusAction,
    ReqPlusTransfer
}

struct UserReqs {
    TypedData tokenReq;
    TypedData[] otherReqs;
}

struct UserReqsAndAction {
    UserReqs reqs;
    bytes32 target;
    bytes message;
}

struct UserReqsAndTransfer {
    UserReqs reqs;
    bytes32 recipient;
}

struct Step {
    StepType typ;
    RefundSettings refundSettings;
    TypedData userSubstep;
    bytes[] parts; // user-defined settings (often guardrails) for other steps
}

struct MerkleOrder {
    bytes32 salt;
    bytes32 routesRoot;
}

struct TokenAmount {
    address token;
    uint256 amount;
}

enum NextStepsType {
    PlainArray, // Step[]
    PlainRecursive, // StepAndNext
    Obfuscated // bytes32
}

struct StepAndNext {
    Step curStep;
    TypedData nextSteps;
}

struct MerkleRoute {
    StepAndNext stepAndNext;
    bytes32[] proof;
}

// Forwarding information is provided by the submitter and acts as a guide to what tokens to transfer betwee different
// contracts involved
enum ForwardingAmountsType {
    OnlyErc20,
    Erc20AndNative,
    MultiErc20,
    MultiErc20AndNative
}

struct ForwardingErc20 {
    TokenAmount tokenAmount;
}

struct ForwardingErc20AndNative {
    ForwardingErc20 erc20;
    uint256 nativeAmount;
}

struct ForwardingMultiErc20 {
    TokenAmount[] tokenAmounts;
}

struct ForwardingMultiErc20AndNative {
    ForwardingMultiErc20 erc20;
    uint256 nativeAmount;
}

struct SubmitterData {
    TokenAmount[] extraFunding;
    TypedData forwardingToExecutor;
    bytes[] parts; // This can have forwardingToUserExecutor as the last part
}

enum TransferType {
    Push,
    ApproveTransferFrom,
    Permit2,
    TransferWithAuthorization
}

abstract contract OrderGateway {
    function submit(
        MerkleOrder calldata order,
        MerkleRoute calldata route,
        TypedData calldata funding,
        SubmitterData calldata submitterData
    ) external payable virtual;
}

abstract contract Executor {
    function execute(
        bytes32 orderId,
        // Note: `userTokenAmount` is trusted by the executor and used to execute substeps that require price information.
        // In canonical order flows, `execute` is called by trusted contracts, so fine to trust these values
        // Note: alternatively, userTokenAmount can be the only approval-transferFrom to ensure that this amount is correct
        // instead of relying onlyOrderGateway / onlyOrderStore for trust
        TokenAmount calldata userTokenAmount,
        StepAndNext calldata stepAndNext,
        address submitter,
        bytes[] calldata submitterParts
    ) external payable virtual; // onlyOrderGateway / onlyOrderStore
}

interface IUserActionExecutor {
    function execute(
        bytes32 orderId,
        TokenAmount calldata tokenAmount,
        bytes calldata actionParams, // params for the execution on the current chain
        TypedData calldata nextSteps // steps to pass along
    ) external payable;
}

abstract contract OrderStore {
    function handle(
        bytes32 orderId,
        TokenAmount calldata tokenAmount,
        TypedData calldata steps
    ) external payable virtual;

    // handle + fill immediately
    function handleAtomic(
        bytes32 orderId,
        TokenAmount calldata tokenAmount,
        TypedData calldata steps,
        // Note: submitter here is technically untrusted. However, it's up to the user on src chain to ensure that they're
        // setting a receiving contract on the DST chain that will only allow a valid submitter value here (think, DstCctpPeriphery
        // that will allow to finalize cctp + handleAtomic and just pass in msg.sender). It's on the underlying bridge to
        // ensure the validity of the message passed, and on the receiving periphery contract to ensure the correctness of
        // submitter address passed
        address submitter,
        SubmitterData calldata submitterData
    ) external payable virtual;

    function fill(uint256 localOrderIndex, SubmitterData calldata submitterData) external payable virtual;
}
