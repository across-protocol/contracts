// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import { MulticallHandler } from "../handlers/MulticallHandler.sol";

/// @title Executor
/// @notice OrderGateway executor that reuses MulticallHandler's multicall infrastructure.
///         Owner defines their calls in stepMessage (fixed order, committed to in the step).
///         Submitter defines the interleaving + their own calls in executorMessage.
///
///         stepMessage     = abi.encode(Call[] ownerCalls)
///         executorMessage = abi.encode(bytes callSources, Call[] submitterCalls)
///
///         Each byte in callSources: 0x00 = next owner call, 0x01 = next submitter call.
///         Owner calls always execute in their committed order — the submitter controls
///         where their calls are inserted but cannot reorder or skip owner calls.
contract Executor is MulticallHandler {
    error CallSourceOutOfBounds();
    error OwnerCallsNotFullyExecuted();

    function execute(address, bytes calldata stepMessage, bytes calldata executorMessage) external payable {
        Call[] memory ownerCalls = abi.decode(stepMessage, (Call[]));
        (bytes memory callSources, Call[] memory subCalls) = abi.decode(executorMessage, (bytes, Call[]));

        Call[] memory merged = new Call[](callSources.length);
        uint256 oi;
        uint256 si;

        for (uint256 i; i < callSources.length; ++i) {
            if (callSources[i] == 0x01) {
                if (si >= subCalls.length) revert CallSourceOutOfBounds();
                merged[i] = subCalls[si++];
            } else {
                if (oi >= ownerCalls.length) revert CallSourceOutOfBounds();
                merged[i] = ownerCalls[oi++];
            }
        }

        // Ensure all owner calls were included — submitter can't skip any
        if (oi != ownerCalls.length) revert OwnerCallsNotFullyExecuted();

        this.attemptCalls(merged);
    }
}
