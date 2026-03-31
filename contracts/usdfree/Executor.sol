// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import { MulticallHandler } from "../handlers/MulticallHandler.sol";

/// @title Executor
/// @notice OrderGateway executor that reuses MulticallHandler's multicall infrastructure.
///         Owner encodes static calls in stepMessage (pull tokens, approve router).
///         Submitter encodes dynamic calls in executorMessage (swap route, send output back).
///         Both encode Call[] arrays — owner calls run first, then submitter calls.
contract Executor is MulticallHandler {
    function execute(address, bytes calldata stepMessage, bytes calldata executorMessage) external payable {
        this.attemptCalls(abi.decode(stepMessage, (Call[])));
        if (executorMessage.length > 0) {
            this.attemptCalls(abi.decode(executorMessage, (Call[])));
        }
    }
}
