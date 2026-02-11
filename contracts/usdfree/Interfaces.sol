// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

/*
Simplified authorization model:
- User approves Order/MerkleOrder.
- Submitter provides funding/actions and optional auction authorization payloads.
- Auction module is pluggable and returns changes.
- Executor enforces user policy while applying changes.

Order identity:
- Single id: orderId.
- Derived on source from user-approved payload.
- Propagated as metadata; not trusted as an auth primitive on destination chains.
*/

enum TokenHandoffMethod {
    Push, // Executor transfers tokens to IUserActionExecutor before execute().
    ApprovePull, // Executor approves IUserActionExecutor to pull.
    Permit2Pull // Executor grants Permit2 allowance; IUserActionExecutor (or downstream) pulls via Permit2.
}

enum TokenAmountMode {
    ExecutorBalance, // Use executor's full balance of tokenReq.token.
    TokenReqAmount, // Use tokenReq.amount.
    ExplicitAmount // Use explicitAmount.
}

struct TokenHandoff {
    TokenHandoffMethod method;
    TokenAmountMode amountMode;
    uint256 explicitAmount; // only used when amountMode == ExplicitAmount
    bytes data; // mode-specific params, e.g. Permit2 details.
}

struct ExecutionStep {
    /*
    NOTE: tokenReq is mandatory:
    - amount == 0 means no enforcement.
    - token informs the final user action.
    */
    bytes tokenReq; // (token, amount) or chain-specific equivalent.
    bytes submitterReq; // empty OR address/bytes32.
    bytes deadlineReq; // empty OR deadline value.
    bytes[] otherStaticReqs;
    bytes hashOrUserAction;
    address refundRecipient;
    TokenHandoff tokenHandoff;
}

enum AuctionInvocationMode {
    Disabled,
    RequiredByStepBitmap
}

/*
Each route defines one module and the steps where it must be invoked.
Routes are user-approved. Executor should enforce that bitmaps are disjoint.
*/
struct AuctionRoute {
    address module;
    bytes stepBitmap; // bit i == 1 means route applies to step i.
    bytes policyData; // module/executor policy constraints approved by user.
}

struct UserAuctionSettings {
    AuctionInvocationMode mode;
    AuctionRoute[] routes;
}

// User-approved single-path intent.
struct Order {
    bytes32 salt;
    ExecutionStep[] steps;
    UserAuctionSettings auctionSettings;
}

// User-approved multi-path intent.
struct MerkleOrder {
    bytes32 salt;
    bytes32 pathRoot;
    uint256 pathCount;
}

// Submitter-proposed path for MerkleOrder; verified against pathRoot.
// Auction settings are path-specific and therefore part of the selected leaf.
struct SelectedPath {
    ExecutionStep[] steps;
    UserAuctionSettings auctionSettings;
    bytes32[] proof;
}

/*
Optional auction authorization.
- Offchain auction: signed/proven by auction authority.
- Fully onchain auction: signatureOrProof can be empty and auctionData can be pure witness.
*/
struct AuctionAuthorization {
    bytes32 orderId;
    uint256 stepIndex;
    uint256 targetChainId;
    address targetContract;
    uint256 deadline;
    bytes auctionData;
    bytes signatureOrProof;
}

// One payload per route invocation on this step.
struct RouteAuthorization {
    uint256 routeIndex;
    AuctionAuthorization authorization;
}

struct AuctionRuntime {
    RouteAuthorization[] routeAuthorizations;
}

struct TokenAmount {
    address token;
    uint256 amount;
}

struct SubmitterData {
    TokenAmount[] extraFunding;
    bytes actions;
    bytes deobfuscation;
}

struct UserAuthorizationData {
    // Protocol-specific gasless/auth payload. Empty for direct user submission flows.
    bytes authorization;
    // Optional metadata hint (e.g. protocol type id / selector). Can be empty.
    bytes authType;
}

struct SubmitterProvided {
    bytes funding;
    UserAuthorizationData userAuthorizationData;
    SubmitterData submitterData;
    AuctionRuntime auctionRuntime;
}

// Metadata propagated between execution layers.
struct OrderMeta {
    bytes32 orderId;
    bytes32 selectedPathHash; // zero for single-path orders.
    UserAuctionSettings auctionSettings;
    address funder; // entity that provided funding on source for this order.
    address submittedBy; // source-chain submitter that opened the order.
    bytes32 userAuthorizationHash; // keccak256 of user auth payload used on source (if any).
}

// Generic auction context.
struct AuctionContext {
    bytes32 orderId;
    bytes32 selectedPathHash;
    uint256 stepIndex;
    address submitter;
    uint256 chainId;
}

// Auction module output.
struct ProposedChange {
    // module-specific enum value (tokenReq/submitterReq/deadline/custom/pathSwitch/etc.)
    uint8 typ;
    // 0 = current step, N = Nth element in nextSteps.
    uint256 relativeStepIndex;
    bytes data;
}

struct ProposedChangeSet {
    ProposedChange[] changes;
}

interface IAuctionModule {
    /*
    Verifies authorization/witness and returns changes.
    Module correctness + policy enforcement are module responsibilities.
    */
    function resolve(
        AuctionContext calldata context,
        AuctionRoute calldata route,
        AuctionAuthorization calldata authorization,
        ExecutionStep calldata currentStep,
        ExecutionStep[] calldata nextSteps
    ) external view returns (ProposedChangeSet memory);
}

abstract contract OrderGateway {
    // Single path.
    function submit(Order calldata order, SubmitterProvided calldata submitterProvided) external payable virtual;

    // Merkle path with submitter-selected path proof.
    function submitMerkle(
        MerkleOrder calldata order,
        SelectedPath calldata selectedPath,
        SubmitterProvided calldata submitterProvided
    ) external payable virtual;
}

abstract contract Executor {
    /*
    Execute one step:
    - run submitter actions
    - invoke required auction routes for this step (per bitmap)
    - apply returned changes under policy
    - validate requirements
    - hand tokens to IUserActionExecutor according to tokenHandoff
    - call IUserActionExecutor.execute()
    */
    function execute(
        address submitter,
        uint256 stepIndex,
        OrderMeta calldata orderMeta,
        AuctionRuntime calldata auctionRuntime,
        bytes calldata submitterActions,
        ExecutionStep calldata currentStep,
        ExecutionStep[] calldata nextSteps
    ) external payable virtual;
}

interface IUserActionExecutor {
    function execute(
        address token,
        uint256 amount,
        bytes calldata actionParams,
        ExecutionStep[] calldata nextSteps,
        OrderMeta calldata orderMeta,
        TokenHandoff calldata tokenHandoff
    ) external payable;
}

abstract contract OrderStore {
    function handle(
        address token,
        uint256 amount,
        ExecutionStep[] calldata remainingSteps,
        OrderMeta calldata orderMeta
    ) external payable virtual;

    function handleAtomic(
        address token,
        uint256 amount,
        ExecutionStep[] calldata remainingSteps,
        OrderMeta calldata orderMeta,
        address submitter,
        SubmitterData calldata submitterData,
        AuctionRuntime calldata auctionRuntime
    ) external payable virtual;

    function fill(
        uint256 localOrderIndex,
        SubmitterData calldata submitterData,
        AuctionRuntime calldata auctionRuntime
    ) external payable virtual;
}
