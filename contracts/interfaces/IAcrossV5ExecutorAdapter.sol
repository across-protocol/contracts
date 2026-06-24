// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

/// @notice Adapter interface for stateful executor handoffs (ADAPTER_CALL).
/// @dev No return value: the Executor invokes adapters with a raw low-level call and discards
/// success returndata, so adapter results must be observed via state or balance requirements.
interface IAcrossV5ExecutorAdapter {
    function adapterExecuteAcrossV5(bytes calldata input, bytes calldata jitData) external payable;
}
