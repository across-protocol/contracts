// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

/**
 * @notice Across V5 adapter interface for stateful Executor handoffs (ADAPTER_CALL command targets). Canonical
 * definition lives in the Across V5 periphery repository.
 * @dev No return value: the Executor invokes adapters with a raw low-level call and discards success returndata,
 * so adapter results must be observed via state or balance requirements.
 */
interface IAcrossV5ExecutorAdapter {
    /// @param input   Tape-committed adapter input.
    /// @param jitData Submitter-provided dynamic data.
    function adapterExecuteAcrossV5(bytes calldata input, bytes calldata jitData) external payable;
}
