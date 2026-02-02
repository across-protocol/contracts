// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

struct ExecutionStep {
    bytes tokenReq; // MANDATORY: (token, amount). Token has to be correct. Amount can be 0 to mean "no enforcement"
    bytes submitterReq; // None OR address (can be bytes32 for non-EVM chains)
    bytes deadlineReq; // None OR deadline
    // A list of other requiremens that can be checked in a static way after the submitter has already executed
    bytes[] otherStaticReqs;
    // NOTE: if we want obfuscation to encompass both the requirements and the actions, we can record
    // auction `Changes` and apply them after the deobfuscation
    // User-defined action that will be executed with the balance of tokenReq.token
    bytes hashOrFinalAction; // can be obfuscated
    // Recipient that can withdraw funds after the deadline if the order hasn't been submitted yet
    bytes32 refundRecipient;
}

// The struct that the user signs. Contains all of the user's preferences
struct Order {
    bytes32 salt;
    ExecutionStep[] steps;
}

// Same as above, if a user is using an auction
struct OrderWithAuction {
    Order order;
    // `auctionAuthority` has the power to change the execution steps (see `struct Change` below)
    address auctionAuthority;
}

struct Change {
    // index of the step this change belongs to
    uint8 stepIndex;
    // token, deadline or submitter change
    bytes change;
}

// Auction changes can do things like change the submitter, improve the token requirement or shorten the deadline etc.
struct AuctionChanges {
    Change[] changes;
    // sig is over (orderId, changes) by the auction authority specified in OrderWithAuction
    bytes sig;
}

struct TokenAmount {
    address token;
    uint256 amount;
}

// Provided to support the execution of a singel step
struct SubmitterData {
    TokenAmount[] extraFunding;
    bytes executions; // weiroll
    bytes deobfuscation; // if user actions are obfuscated
}

contract OrderGateway {
    function submit(Order calldata order, SubmitterData calldata submitterData, bytes calldata gaslessSig) external payable;
    function submitWithAuction(
        OrderWithAuction memory order,
        SubmitterData calldata submitterData,
        bytes calldata gaslessSig,
        AuctionChanges calldata auctionChanges
    ) external payable;
}

contract Executor {
    // TODO: IMO it makes sense to have executor check submitter requirement too. I don't think it matters much though
    function execute(
        // NOTE: submitter is propagated by the caller: either Gateway or `IntentStore`
        address submitter;
        // NOTE: these are provided by the submitter to try to meet user's requirements
        bytes submitterExecutions; // weiroll
        // NOTE: these are taken from the current `ExecutionStep`
        bytes tokenReq,
        bytes submitterReq,
        bytes deadlineReq,
        // A list of other requiremens that can be checked in a static way after the submitter has already executed
        bytes[] otherStaticReqs;
        bytes memory finalActionParams,
        // NOTE: these are the remaining execution steps, initially defined by the user in `Order.steps`
        ExecutionStep[] nextSteps
    ) external;
}

// NOTE: it is a task of `FinalUserActionExecutor` to propagate `nextSteps` to the future execution layer
interface FinalUserActionExecutor {
    function executeFinal(
        // NOTE: this is taken from `ExecutionStep.tokenReq.token`
        address token,
        // NOTE: this is taken from `balanceOf(executorContract, ExecutionStep.tokenReq.token)`
        uint256 amount,
        // NOTE: these are hardcoded in the `ExecutionStep.hashOrFinalAction`
        bytes memory finalActionParams,
        // NOTE: these are the remaining execution steps, initially defined by the user in `Order.steps`
        ExecutionStep[] nextSteps
    ) external;
}
