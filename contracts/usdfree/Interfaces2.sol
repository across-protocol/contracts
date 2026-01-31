// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

/*
One of key problems:

How much do we want to embed the auciton in this initial design?
For example, auction authority can be used to check a submitter.
However, depdending on the shape of the submitterRequirement from the auction,
we could be checking an extra token requirement too. This is some auction-induced
requirement.

It's hard for us to do it in this design, since we're checking the submitter requirement
on the Gateway / IntentHandler, not on the executor, and making submitter requirement a
special case.

We need to either propagate the extra token requirement to the Executor, or propagate the
submitter data to the Executor to check the submitter data there and then check all of the
static requirements in one place.

One more nice thing that we can do is call (on executor, after submitterActions) _checkReqsAndPerformUserActions(..)
This way we could, depending on the version of requirements, for example check the token balance in the token req. at
the end of the execution to see that it's zero (meaning that user actions sucessfully used the tokens)

NOTE: all in all, bringing some extra token requirement from the auction on-chain is painful and I think should be avoided.
One other thing that's not clear: if a submitter is defined on a src chain by the auction, the submitter can sign over
orderId, submitterAddr. However, orderId is not propagated to the dst chain: how to deal with deciding the submitter there?

One way to deal with all of this is some RFQ system, where a user posts some intent, then a submitter commits to an intent,
only then the user sings a TX with a specific src + dst submitter (no auction sig checking)
*/

struct OrderBase {
    address tokenIn;
    uint256 amountIn;
    // NOTE: these are checked internally in Executor via some `_checkRequirements(bytes memory reqs)` call.
    // requirements can have a version where a v1 or reqs are: tokenReq, deadlineReq but can be extended in the future
    bytes staticRequirements;
    // TODO: contains staticRequirements + submitterRequirement for the next chain
    // TODO: it'd be much easier to just propagate the submitter and check the submitter
    // TODO: requirement on the executor too.
    // TODO: then ONLY the deobfusctaion is on the OrderStore. Gateway does not need the deobfuscation functionality
    bytes finishData;
}

interface IFinisherInterface {
    // TODO: What shape should the additional requirements take so that they're seamlessly added?
    // TODO: I guess the added can pick the shape
    // TODO: this `finishData` can be obfuscated
    function finish(bytes memory finishData, bytes[] memory additionalRequirements) external;
}

// TODO: what gets sent to the dst chain?
// TODO: it is a job of the finisher to compose staticRequirements out of the finishData and additionalRequirements
struct OrderCore {
    bytes staticRequirements;
    bytes finishData; // TODO: this is the finishData for the next chain
}

// The thing that the user signs (puts as witness into the gasless sig, or submits themselves)
struct Order {
    bytes32 salt;
    bytes submitterRequirement;
    OrderBase base;
}

// Base contract for Gateway and OrderStore: shared deobfuscation logic
// NOTE: submitterRequirement is not checked here - caller is responsible.
abstract contract OrderExecutionBase {
    // This function expects all starting token balances (user's and submitter's) to be on the Executor balance already
    function _execute(
        bytes memory staticRequirements,
        bytes memory hashOrActions, // abi-encoded MulticallHandler.Instructions
        bytes memory deobfuscation, // bytes(0) if not obfuscated
        bytes memory submitterActions // weiroll commands
    ) internal virtual {
        // 1. deobfuscate hashOrActions if needed
        // 2. call Executor.execute(submitterActions, requirements, userActions)
    }
}

// src-side entrypoint with token approvals
contract OrderGateway is OrderExecutionBase {
    function submit(
        Order memory order,
        bytes memory gaslessData, // empty=pre-approved, or permit/permit2/EIP-3009 sig
        bytes memory submitterRequirementResponse, // for example, auction authority signature
        bytes memory submitterFunding, // array of (token, amount)
        bytes memory submitterActions // weiroll commands
    ) external payable {
        // 1. check submitterRequirement
        // 2. pull user's tokens (interpret gaslessData)
        // 3. pull submitter's tokens
        // 4. push all tokens to executor
        // 5. _execute(order.base.requirements, order.base.userActions, bytes(0), submitterActions)
    }
}

// OFT handler -> OrderStore.handle
// CCTP handler -> OrderStore.handle

// SpokePool

/*

1. submitter actions (swaps)
-- SpokePool.fill entrypoint --
2. requirement checks (don't change state)
3. final user action

OPTION 1:
3: OrderStore.handleAtomic:
1. submitter actions
2. req. checks
3. final user action

OPTION 2:
Let relayer call PermissionedMulticallHandler:
1. do swaps
2. call fill on the SpokePool 

exclusivity problems?

OPTION 3:
callback in the middle of `fillWithCallback`

*/

// dst-side contract with token approvals
contract OrderStore is OrderExecutionBase {
    // Tries atomic execution with empty submitter actions. If fails, stores order.
    function handle(
        OrderBase memory orderBase,
        bytes memory submitterRequirement // NOT checked, only stored for check on `fillStored` if required
    ) external payable {
        // 1. pull tokens from msg.sender
        // TODO: push and then try does not bring the tokens back. Fix it. One way is to have Executor pull tokens.
        // TODO: can do something like try delegatecall self where the push + execute happens. Then if that reverts,
        // TODO: the token push gets reverted too right?
        // 2. push tokens to executor
        // 3. try _execute(orderBase.requirements, orderBase.userActions, bytes(0), [])
        // 4. if fails, store (orderBase.userActions, submitterRequirement) for later fill
    }

    // Atomic execution. Caller (example of happy-path caller is CCTPHandler) is responsible for checking
    // submitterRequirement BEFORE forwarding funds and calling this.
    function handleAtomic(
        OrderBase memory orderBase,
        bytes memory deobfuscation, // bytes(0) if not obfuscated
        bytes memory submitterRequirementResponse, // for example, auction authority signature
        bytes memory submitterFunding, // array of (token, amount)
        bytes memory submitterActions // weiroll commands
    ) external payable {
        // 1. pull tokens from msg.sender
        // 2. pull submitter's tokens
        // 3. push all tokens to executor
        // 4. _execute(order.base.requirements, order.base.userActions, bytes(0), submitterActions)
    }

    // Fill a stored intent. Checks stored submitterRequirement.
    function fillStored(
        uint256 intentIndex,
        bytes memory deobfuscation,
        // TODO?
        bytes memory submitterRequirementResponse, // for example, auction authority signature
        bytes memory submitterFunding, // array of (token, amount)
        bytes memory submitterActions // weiroll commands
    ) external payable {
        // 1. load stored (orderBase, submitterRequirement)
        // 2. check submitterRequirement
        // 3. pull submitter's tokens
        // 4. push all tokens to executor
        // 5. _execute(orderBase, deobfuscation, submitterActions)
    }
}

// Stateless executor. No approvals, runs arbitrary calls. Assumes all balances are "there for the taking" during atomic execution
contract OrderExecutor {
    function execute(
        bytes memory submitterActions, // weiroll commands
        bytes memory staticRequirements,
        bytes memory userActions // abi-encoded MulticallHandler.Instructions
    ) external payable {
        // 1. run submitterActions (weiroll)
        // 2. check requirements in an internal function. Call something like `_checkReqsAndExecuteUserActions(staticReqs, userActions)`
        // 3. run userActions (MulticallHandler patterns)
    }
}
