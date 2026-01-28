// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

/*
NOTE:
I think it makes the most sense to obfuscate user-specified actions on the dst chain (since they actually change some
state and may be exploited somehow)
*/

struct DstMessage {
    bool obfuscated;
    bytes data; // hash if obfuscated
}

// for example: token, balanceOf(address(some-contract))
struct StaticCallRequirement {
    address target;
    bytes cdata;
}

struct Order {
    bytes32 salt; // for `orderId` generation
    address tokenIn;
    uint256 amountIn;
    StaticCallRequirement[] requirements;
    // todo: how to safely forward the full balance of some `token` to this call? Should Call have a token?
    // todo: finalCall should also probably have different operation modes: push tokens vs pull tokens (approve reciever)

    // todo: should these be "finalCalls"? And then Executor takes on a role of a MulticallHandler of sorts? Because
    // todo: we could be required to do something like an [Approval, Deposit] to complete the flow
    Call finalCall;
}

// todo: take from MulticallHandler
struct Call {
    address target;
    bytes cdata;
    uint256 value;
}

struct TokenAmount {
    address token;
    uint256 amount;
}

// todo: ask Claude to try to embed weiroll calls into here instead of Call. Will we need a separate funding field anyway? I assume so
struct SubmitterData {
    bytes submitterReqResponse; // something like an auction sig, if necessary
    Call[] calls; // arbitrary calls that are going to execute before checking user requirements on src chain
    TokenAmount[] funding; // extra funding submitter wants to provide
}

contract OrderGateway {
    // todo: maybe submitterCalls can be weiroll objects? Instead of using Multicall-like structs.
    function submit(Order memory order, SubmitterData memory submitterData) external payable {
        // check submitter requirement
        // pull all tokens
        // forward to executor for
    }
}

// todo: this is a contract that has very loose permissions. It should support MulticallHandler-like functionality (like substituting some calldata with own balances)
// todo: perhaps, it should heavily utilize weiroll
// todo: always assumes that it has zero balances at the start of the sequence. Operates with balances
contract OrderExecutor {
    function execute(
        Call[] memory submitterCalls,
        StaticCallRequirement[] memory reqs,
        Call[] memory finalCalls
    ) external payable {
        // perform submitterCalls
        // check reqs in linear order (all static calls)
        // perform finalCalls in linear order
    }
}

// todo: dst-side interfaces

contract IntentStore {
    function submit() external {}
}
