// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.18;

/// @notice Minimal Across V5 Executor entrypoint. The Gateway invokes the path's chosen executor with
///         `execute(path.message, submitterInputs.executorMessage)`. {SpokePoolV5} implements this so a path may
///         name the SpokePool directly as its executor (`Gateway -> SpokePool`).
/// @dev Mirrors `contracts-v5/src/interfaces/IExecutor.sol` (function surface only). Shares its selector with
///      {IExecutorAdapter.execute}, so a single implementation satisfies both.
interface IExecutor {
    function execute(bytes calldata message, bytes calldata executorMessage) external payable;
}
