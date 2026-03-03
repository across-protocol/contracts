// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

struct TypedData {
    uint8 typ;
    bytes data;
}

// Defines sequence of substeps performed as a part of that step
enum StepType {
    // 1. Alter user reqs
    // Note. Alter user requirements can take many different forms. For example, an offchain auction authority can sign
    // over some payload to bump up the user's balanceReq. Or a user can trust a submitter (e.g. RL submitter) to bump
    // up balanceReq (effectively, this is the same as having auction authority == RL submitter). Alternatively, imagine
    // an Alter substep that: takes token amount in (from mint on dst chain), takes onchain oracle price, takes user
    // BPS discount / premium required, alters balanceReq: balanceReq = tokenIn * price * (1 + bps_disc_or_premium)
    // 2. Submitter actions to meet user reqs (MulticallHandler instructions or weiroll)
    // 3. User req checks and action/transfer (see UserReqsAndAction / UserReqsAndTransfer)
    AlterSubmitterUser,
    // only 2. and 3.
    SubmitterUser,
    // only 3.
    User
}

struct RefundSettings {
    bytes32 refundRecipient;
    uint256 reverseDeadline;
}

enum AlterSubstepType {
    OffchainAuction, // user specifies auction authority
    DutchOnchainAuction, // user specifies dutch auction params
    OffchainAuctionWithDutchOnchainFallback, // user specifies offchain auction authority + fallback deadline + onchain dutch auction params
    PriceOraclePlusDelta, // user specifies oracle address plus a delta (discount or permium) that they expect
    SimpleSubmitterAlter // user doesn't specify anything besides the type. Submitter (checked by submitterReq) has the option to bump the user balanceReq up (e.g. a trusted submitter like RL submitter)
}

enum UserSubstepType {
    ReqPlusAction,
    ReqPlusTransfer
}

enum UserReqType {
    Deadline,
    Submitter,
    Staticcall
}

struct UserReqs {
    TypedData balanceReq;
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
    // TODO: `parts` are inherently not very robust. A mismatch between a part and an expected sequence can lead to incorrect
    // TODO: interpretation of parts. Should each `part` have some sort of signature(like a 4-byte function sig) to signify
    // TODO: what is the supposed meaning of that part? E.g. we can have a global `enum Parts`, that will contain all of the
    // TODO: possible part variants and will be checked for each part. Parts then can be TypedData
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

struct SubmitterData {
    TokenAmount[] extraFunding;
    bytes[] parts;
}

enum OrderFundingType {
    Approval,
    Permit2,
    TransferWithAuthorization
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
}

interface IOrderGateway {
    function submit(
        MerkleOrder calldata order,
        MerkleRoute calldata route,
        // Funding by the party authorizing the order. Funding has the amount of a single ERC20 token
        TypedData calldata orderFunding,
        SubmitterData calldata submitterData
    ) external payable;
}

interface IExecutor {
    function execute(
        bytes32 orderId,
        TokenAmount calldata userTokenAmount,
        StepAndNext calldata stepAndNext,
        address submitter,
        bytes[] calldata submitterParts
    ) external payable; // onlyOrderGateway / onlyOrderStore
}

interface IUserActionExecutor {
    function execute(
        bytes32 orderId,
        TokenAmount calldata tokenAmount,
        bytes calldata actionParams, // params for the execution on the current chain
        TypedData calldata nextSteps // steps to pass along
    ) external payable;
}

interface IOrderStore {
    function handle(bytes32 orderId, TokenAmount calldata tokenAmount, TypedData calldata steps) external payable;

    // handle + fill immediately
    function handleAtomic(
        bytes32 orderId,
        TokenAmount calldata tokenAmount,
        TypedData calldata steps,
        // Note: submitter here is technically an untrusted argument. However, it's up to the user on src chain to ensure that they're
        // setting a receiving contract on the DST chain that will only allow a valid submitter value here (think, DstCctpPeriphery
        // that will allow to finalize cctp + handleAtomic and just pass in msg.sender). It's on the underlying bridge to
        // ensure the validity of the message passed, and on the receiving periphery contract to ensure the correctness of
        // submitter address passed
        address submitter,
        SubmitterData calldata submitterData
    ) external payable;

    function fill(uint256 localOrderIndex, SubmitterData calldata submitterData) external payable;
}
