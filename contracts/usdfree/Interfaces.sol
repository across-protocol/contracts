// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

// Static checks that cannot modify state
struct StaticRequirement {
    address target;
    bytes cdata;
}

struct OrderBase {
    address tokenIn;
    uint256 amountIn;
    StaticRequirement[] requirements;
    bytes userActions; // abi-encoded MulticallHandler.Instructions
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
        StaticRequirement[] memory requirements,
        bytes memory userActions, // abi-encoded MulticallHandler.Instructions
        bytes memory deobfuscation, // bytes(0) if not obfuscated
        bytes memory submitterActions // weiroll commands
    ) internal virtual {
        // 1. deobfuscate orderBase.userActions if needed
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

// dst-side contract with token approvals
contract OrderStore is OrderExecutionBase {
    // Tries atomic execution with empty submitter actions. If fails, stores order.
    function handle(
        OrderBase memory orderBase,
        bytes memory submitterRequirement // NOT checked, only stored for check on `fillStored` if required
    ) external payable {
        // 1. pull tokens from msg.sender
        // TODO: push and then try does not bring the tokens back. Fix it. One way is to have Executor pull tokens.
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
        StaticRequirement[] memory requirements,
        bytes memory userActions // abi-encoded MulticallHandler.Instructions
    ) external payable {
        // 1. run submitterActions (weiroll)
        // 2. check requirements (staticcall each, revert if any fails)
        // 3. run userActions (MulticallHandler patterns)
    }
}
