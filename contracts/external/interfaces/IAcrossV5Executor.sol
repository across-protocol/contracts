// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

/**
 * @notice Across V5 executor interface. The Gateway calls the path-committed executor through this entrypoint
 * after verifying the path and running the funding loop. Canonical definition lives in the Across V5 periphery
 * repository.
 */
interface IAcrossV5Executor {
    /// @notice Execute a path's committed message.
    /// @param message         The path-committed message.
    /// @param executorMessage Submitter-provided dynamic data.
    function executeAcrossV5(bytes calldata message, bytes calldata executorMessage) external payable;
}
