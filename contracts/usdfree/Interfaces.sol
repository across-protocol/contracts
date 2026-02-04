// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

struct ExecutionStep {
    /*
    NOTE: `tokenReq` is a mandatory param:
    - amount == 0 means no enforccement
    - token is used to inform the final user action. The action is made with (tokenReq.token, balanceOf(tokenReq.token, address(this))) on the executor
    */
    bytes tokenReq; // (token, amount)
    // NOTE: if an order is sponsored, this is forced by the API to be one of the trusted relayers, to prevent self-
    // submission and self-sandwiching on the sponsored orders
    bytes submitterReq; // None OR address (can be bytes32 for non-EVM chains)
    bytes deadlineReq; // None OR uint256 deadline
    // A list of other requiremens that can be checked in a static way (no state changes) after execution of submitter actions.
    bytes[] otherStaticReqs;
    // NOTE: if we want obfuscation to encompass both the requirements and the final action, we can record auction `Changes`
    // and apply them after the deobfuscation (send them to the next steps similarly to how we send `nextSteps`)
    bytes hashOrUserAction;
    // NOTE: If the current step hasn't been executed by `deadline`, this address can break the execution chain and withdraw
    // the assets associated with the order
    address refundRecipient;
}

// The struct that the user signs/submits. Contains all of the user's preferences
struct Order {
    // NOTE: there's no (token, amount) here that the user submits. That's provided separately at the time of the submit.. call
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
    // ? TODO: hard to create relevant good `witness`, as `orderId` is only present on initial submission. Maybe there's a way?
    // NOTE: only approval-based token pulls are supported from submitters
    TokenAmount[] extraFunding;
    bytes actions; // MulticallHandler.Instructions or weiroll (support can be expanded to any format)
    bytes deobfuscation; // if user's finalAction is obfuscated
}

// Entrypoint contract for all order submissions
abstract contract OrderGateway {
    // NOTE: `funding` here is (token, amount) for approval flows. For gasless flows something like (transfer data object + sig)
    function submit(
        Order calldata order,
        bytes calldata funding,
        SubmitterData calldata submitterData
    ) external payable virtual;

    function submitWithAuction(
        OrderWithAuction memory order,
        bytes calldata funding,
        SubmitterData calldata submitterData,
        AuctionChanges calldata auctionChanges
    ) external payable virtual;
}

// Contract responsible for executing submitter actions, checking user requirements and executing the final user action
abstract contract Executor {
    function execute(
        // `submitter` is propagated by the caller: either `OrderGateway` or `OrderStore`
        address submitter,
        // Provided by the submitter to try to meet user's requirements
        bytes calldata submitterActions, // MulticallHandler.Instructions or weiroll (support can be expanded to any format)
        // Current and the remaining execution steps, initially defined by the user in `Order.steps`
        // NOTE: the executor just executes a `currentStep`, only propagating `nextSteps` to the user action executor
        ExecutionStep calldata currentStep,
        ExecutionStep[] calldata nextSteps
    ) external payable virtual;
}

// NOTE: it is a responsibility of `IUserActionExecutor` to propagate `nextSteps` to the future execution layer
interface IUserActionExecutor {
    function execute(
        // `ExecutionStep.tokenReq.token`
        address token,
        // `balanceOf(address(IExecutor), ExecutionStep.tokenReq.token)`
        uint256 amount,
        // Hardcoded in the `ExecutionStep.hashOrUserAction` either directly or as a cryptographical commitment. Have to
        // be deobfuscated by this point
        bytes calldata actionParams,
        // these are the remaining execution steps, initially defined by the user in `Order.steps`
        ExecutionStep[] calldata nextSteps
    ) external payable;
}

abstract contract OrderStore {
    // Called by a Mint-burn receiver contract after it's done all of the relevant checks and ready to hand over tokens
    function handle(
        // ? TODO: we can be a bit more generic wrt how we handle token pulling here. `bytes calldata funding`
        address token,
        uint256 amount,
        /*
        NOTE: remainingSteps[0] is the "current step" to exeute. If the array is empty, we can't proceed as we don't even
        know the refundAddress from the execution step struct. In this case, we have to store an empty order and allow
        retrieval by admin.
        Maybe src periphery can check that nextSteps is not empty on submission. However, that would lock the src periphery
        to only working with this type of flow (src -> dst -> orderStore). Maybe that _is_ the only required route
        */
        ExecutionStep[] calldata remainingSteps
    ) external payable virtual;

    // Perform a handle + fill atomically. Available for e.g. CCTP finalizers to also be submitters
    function handleAtomic(
        address token,
        uint256 amount,
        ExecutionStep[] calldata remainingSteps,
        // NOTE: propagated by the msg.sender. We can trust this, since msg.sender is providing the funds
        address submitter,
        SubmitterData calldata submitterData
    ) external payable virtual;

    // Fill an order stored in the store
    function fill(uint256 localOrderIndex, SubmitterData calldata submitterData) external payable virtual;
}
