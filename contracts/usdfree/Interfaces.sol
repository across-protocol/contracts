// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

struct ExecutionStep {
    bytes tokenReq; // Mandatory: (token, amount). Token has to be correct. Amount can be 0 to mean "no enforcement"
    // NOTE: if an order is sponsored, this is forced by the API to be one of the trusted relayers, to prevent self-
    // submission and self-sandwiching on the sponsored orders
    bytes submitterReq; // None OR address (can be bytes32 for non-EVM chains)
    bytes deadlineReq; // None OR deadline
    // A list of other requiremens that can be checked in a static way after the submitter has already executed
    bytes[] otherStaticReqs;
    // NOTE: if we want obfuscation to encompass both the requirements and the final action, we can record auction `Changes` 
    // and apply them after the deobfuscation
    bytes hashOrFinalAction;
    // NOTE: If the current step hasn't been executed by `deadline`, this address can break the execution chain and withdraw
    // the assets associated with the order
    address refundRecipient;
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

// A struct that represents some change in user requirement as a result of the auction
struct Change {
    // enum for: token, deadline, submitter or custom
    uint8 typ;
    // NOTE: if a type is custom, data can inlcude an index of the otherStaticReqs that the auction wants to change. The
    // funtion to apply the change has to be implemented on the OrderGateway for this to work
    // data gets interpreted by the Gateway to apply the change depending on the type
    bytes data;
}

// Auction changes can do things like change the submitter, improve the token requirement or shorten the deadline etc.
struct AuctionChanges {
    // changes[idx] are relevant to the requirements of order.steps[idx]
    Change[][] changes;
    // sig is over (orderId, changes) by the auction authority specified in OrderWithAuction
    bytes sig;
}

struct TokenAmount {
    address token;
    uint256 amount;
}

// Provided to support the execution of a single step
struct SubmitterData {
    TokenAmount[] extraFunding;
    bytes actions; // weiroll
    bytes deobfuscation; // if user's finalAction is obfuscated
}

// Entrypoint for all order submissions
contract OrderGateway {
    function submit(Order calldata order, SubmitterData calldata submitterData) external payable;
    function submitGasless(Order calldata order, SubmitterData calldata submitterData, bytes calldata gaslessSig) external payable;
    function submitWithAuction(
        OrderWithAuction memory order,
        SubmitterData calldata submitterData,
        bytes calldata gaslessSig,
        AuctionChanges calldata auctionChanges
    ) external payable;
}

// Contract responsible for executing submitter actions, checking user requirements and executing the final user action
interface Executor {
    function execute(
        // `submitter` is propagated by the caller: either Gateway or `IntentStore`
        address submitter,
        // Provided by the submitter to try to meet user's requirements
        bytes calldata submitterActions, // weiroll
        // Current and the remaining execution steps, initially defined by the user in `Order.steps`
        ExecutionStep calldata currentStep,
        ExecutionStep[] calldata nextSteps
    ) external payable;
}

// NOTE: it is a task of `FinalUserActionExecutor` to propagate `nextSteps` to the future execution layer
interface FinalUserActionExecutor {
    function executeFinal(
        // this is taken from `ExecutionStep.tokenReq.token`
        address token,
        // this is taken from `balanceOf(executorContract, ExecutionStep.tokenReq.token)`
        uint256 amount,
        // these are hardcoded in the `ExecutionStep.hashOrFinalAction`
        bytes calldata finalActionParams,
        // these are the remaining execution steps, initially defined by the user in `Order.steps`
        ExecutionStep[] calldata nextSteps
    ) external payable;
}

interface OrderStore {
    // Called by a Mint-burn contract after it's done all of the relevant checks and ready to hand over tokens
    function handle(
        address token,
        uint256 amount,
        // NOTE: remainingSteps[0] is the "current step". An array cannot be empty, otherwise we revert and require some
        // `handleAtomic` call by the refund recipient
        ExecutionStep[] calldata remainingSteps
    ) external payable;

    // Perform a handle + fill atomically. Available for e.g. CCTP finalizers to also be submitters
    function handleAtomic(
        address token,
        uint256 amount,
        ExecutionStep[] calldata remainingSteps,
        // NOTE: propagated by the msg.sender. We can trust this, since msg.sender is providing the funds
        address submitter,
        SubmitterData calldata submitterData
    ) external payable;

    // Fill an order stored in the store
    function fill(
        uint256 localOrderIndex,
        SubmitterData calldata submitterData
    ) external payable;
}
