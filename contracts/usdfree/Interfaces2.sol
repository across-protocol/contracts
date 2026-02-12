// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

enum GenericStepType {
    AuctionSubmitterUser,
    SubmitterUser,
    User
}

// `parts` encoding:
// - AuctionSubmitterUser: [abi.encode(AuctionAction), abi.encode(UserRequirementsAndAction)]
// - SubmitterUser: [abi.encode(UserRequirementsAndAction)]
// - User: [abi.encode(UserRequirementsAndAction)]
struct GenericStep {
    GenericStepType typ;
    bytes[] parts;
}

struct AuctionAction {
    bytes4 auctionType;
    bytes authority; // what steps it can change
    bytes auctionData; // relevant data, e.g. params for on-chain Dutch auction or auctionAuthority for offchain auction
}

struct UserRequirementsAndAction {
    // Strict or MinAmount; token, amount
    bytes tokenReq;
    // Submitter, deadline and other requirements
    bytes[] otherStaticReqs;
    // User action executor target for this step
    address target;
    // How tokens are delivered to target
    bytes4 transferType; // Approval, Transfer, Permit2Approval
    // Params for execution on `target`. `orderId` and `nextActionsOrHash` passed separately
    bytes userAction;
    address refundRecipient;
}

struct MerkleOrder {
    bytes32 salt;
    bytes32 routesRoot;
}

struct TokenAmount {
    address token;
    uint256 amount;
}

// Represents a deobfuscated execution chunk where only the current step is explicit.
// `nextStepsOrHash` can be either:
// - abi.encode(GenericStep[]) for transparent continuation, or
// - abi.encode(bytes32) commitment to later deobfuscate recursively.
struct StepAndNext {
    GenericStep curStep;
    bytes nextStepsOrHash;
}

struct MerkleRoute {
    StepAndNext stepAndNext;
    bytes32[] proof;
}

struct SubmitterData {
    TokenAmount[] extraFunding;
    // Optional submitter-provided parts. Typical entries:
    // - actions
    // - offchain auction auth payload (if generic step type is AuctionSubmitterUser and auction type is offchain)
    // - deobfuscation payload
    bytes[] parts;
}

abstract contract OrderGateway {
    function submit(
        MerkleOrder calldata order,
        MerkleRoute calldata route,
        bytes calldata funding,
        SubmitterData calldata submitterData
    ) external payable virtual;
}

abstract contract Executor {
    function execute(
        address submitter,
        bytes32 orderId,
        // TODO: tokens are always just pushed to Executor for gas efficiency. Is it OK? See logic below
        // Note: these values are trusted by the executor and used to enforce price-based auction changes. In canonical
        // order flows, `execute` is called by trusted contracts, so fine to trust these values
        address userTokenIn,
        uint256 userAmountIn,
        bytes[] calldata submitterParts,
        StepAndNext calldata stepAndNext
    ) external payable virtual;
}

interface IUserActionExecutor {
    function execute(
        address token,
        uint256 amount,
        bytes32 orderId,
        bytes calldata actionParams,
        bytes calldata nextStepsOrHash
    ) external payable;
}

abstract contract OrderStore {
    function handle(
        address token,
        uint256 amount,
        bytes32 orderId,
        bytes calldata nextStepsOrHash
    ) external payable virtual;

    function handleAtomic(
        address token,
        uint256 amount,
        bytes32 orderId,
        bytes calldata nextStepsOrHash,
        address submitter,
        SubmitterData calldata submitterData
    ) external payable virtual;

    function fill(uint256 localOrderIndex, SubmitterData calldata submitterData) external payable virtual;
}
