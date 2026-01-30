// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

// NOTE: this creates an explicit separation of user checks and any actions: these cannot modify state and are simple
struct StaticRequirement {
    address target;
    bytes cdata;
}

struct Order {
    bytes32 salt; // for `orderId` generation
    address tokenIn;
    uint256 amountIn;
    StaticRequirement[] requirements;
    bytes userActions; // abi-encoded MulticallHandler.Instructions
}

struct TokenAmount {
    address token;
    uint256 amount;
}

// Gateway: src-side entry point. Has token approvals, forwards execution to Executor.
contract OrderGateway {
    function submit(
        Order memory order,
        bytes memory gaslessData, // empty=pre-approved, or permit/permit2/EIP-3009 sig
        TokenAmount[] memory submitterFunding,
        bytes memory submitterActions // weiroll commands
    ) external payable {
        // 1. pull user's tokens (interpret gaslessData for permit/permit2/3009/etc)
        // 2. transfer submitterFunding to Executor
        // 3. call Executor.execute(submitterActions, order.requirements, order.userActions)
    }
}

// Stateless executor. No approvals, runs arbitrary calls. MUST start with zero balances.
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

// IntentStore: dst-side. Has token approvals, forwards execution to Executor.
contract IntentStore {
    // Tries atomic execution with empty submitter actions. If fails, stores intent.
    // submitterRequirement is stored to be enforced on fillStored.
    function handle(
        StaticRequirement[] memory requirements,
        bytes memory submitterRequirement, // stored, enforced on fill
        bytes memory userActionsOrHash
    ) external payable {}

    // Atomic execution. Caller (CCTPHandler, etc.) checks submitterRequirement if needed.
    function handleAtomic(
        StaticRequirement[] memory requirements,
        bytes memory userActionsOrHash,
        bytes memory deobfuscation, // bytes(0) if not obfuscated
        TokenAmount[] memory submitterFunding,
        bytes memory submitterActions // weiroll commands
    ) external payable {}

    // Fill a stored intent. Enforces stored submitterRequirement.
    function fillStored(
        uint256 intentIndex,
        bytes memory deobfuscation, // bytes(0) if not needed
        TokenAmount[] memory submitterFunding,
        bytes memory submitterActions // weiroll commands
    ) external payable {}
}
