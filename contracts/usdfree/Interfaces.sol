// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

// NOTE: this can, of course, be encoded using weiroll
// for example: token, balanceOf(address(some-contract))
struct StaticRequirement {
    address target;
    bytes cdata;
}

struct Order {
    bytes32 salt; // for `orderId` generation
    address tokenIn;
    uint256 amountIn;
    StaticRequirement[] requirements;
    // NOTE: user calls do not use weiroll, they're supposed to be simpler for screw up protection
    // However, user actions also want to use some weiroll things.
    // TODO: a user could provide [deadlineCheck, balanceCheck + return balance, approve, call] and then user's actions
    // are just appeneded to the weiroll stack. However, we have to combine user's weiroll actions + state with the submitter's
    // Will submitter be able to easily support this?
    Call[] finalCalls;
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

contract OrderGateway {
    // todo: maybe submitterCalls can be weiroll objects? Instead of using Multicall-like structs.
    function submit(
        // user data
        Order memory order,
        // submitter data
        bytes memory deobfuscation, // bytes(0) if not needed
        TokenAmount[] memory submitterFunding,
        // TODO: weiroll might be useful here
        Call[] memory submitterActions
    ) external payable {}
}

// todo: this is a contract that has very loose permissions. It should support MulticallHandler-like functionality (like substituting some calldata with own balances)
// todo: perhaps, it should heavily utilize weiroll
// todo: always assumes that it has zero balances at the start of the sequence. Operates with balances
contract OrderExecutor {
    // TODO: this might all be submitted just using weiroll..
    function execute(
        Call[] memory submitterActions,
        StaticRequirement[] memory orderRequirements,
        Call[] memory orderFinalCalls
    ) external payable {
        // perform submitter actions
        // check order requirements
        // perform order final calls (might insert balance into some of these)
    }
}

contract IntentStore {
    // handle is used in the case when the TX submission chain does not allow for submitter actions
    // handle tries to call .execute with empty submitter actions. If that fails, it stores the intent
    function handle(
        // data of user origin
        StaticRequirement[] memory staticRequirements,
        bytes memory submitterRequirement,
        bytes memory finalActionsOrHash
    ) external payable {}

    // NOTE: submitterReq is never checked on `handleAtomic`. It is expected that the caller will check submitter req
    // if important. If a caller is the EOA, they're free to be calling this as well, although they'll have to provide
    // their own capital to the flow (using user's capital would force them to go through some smart contract first)
    function handleAtomic(
        // data of user origin
        StaticRequirement[] memory reqs,
        bytes memory finalActionsOrHash,
        // data of submitter origin
        bytes memory finalActions, // if `finalActionsOrHash` was obfuscated
        TokenAmount[] memory submitterFunding,
        // TODO: weiroll might be useful here
        Call[] memory submitterActions
    ) external payable {}

    function fillStored(
        // data of user origin is stored on the contract under `index`
        uint256 intentIndex, // index of the stored intent being filled
        // data of submitter origin
        bytes memory deobfuscation, // bytes(0) if not needed
        TokenAmount[] memory submitterFunding,
        // TODO: weiroll might be useful here
        Call[] memory submitterActions
    ) external payable {}
}
