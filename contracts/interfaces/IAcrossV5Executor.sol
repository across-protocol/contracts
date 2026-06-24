// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

interface IAcrossV5Executor {
    // ── Functions ────────────────────────────────────────────────────────

    /// @notice Execute a path's command sequence.
    /// @param message         The path message — encodes (bytes commands, bytes[] inputs).
    /// @param executorMessage Submitter-provided dynamic data.
    function executeAcrossV5(bytes calldata message, bytes calldata executorMessage) external payable;
}
