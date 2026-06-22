// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.18;

/// @notice Minimal Across V5 executor adapter entrypoint. The Executor invokes adapters behind an `ADAPTER_CALL`
///         command as `execute(committedInput, jitData)`. {SpokePoolV5} implements this so the Executor can drive a
///         deposit/fill as one step of a larger command tape (`Gateway -> Executor -> SpokePool`).
/// @dev Mirrors `contracts-v5/src/interfaces/IExecutorAdapter.sol`. Its selector is identical to {IExecutor.execute}
///      (both are `execute(bytes,bytes)` payable), so {SpokePoolV5} satisfies both interfaces with one function.
interface IExecutorAdapter {
    function execute(bytes calldata input, bytes calldata jitData) external payable;
}
