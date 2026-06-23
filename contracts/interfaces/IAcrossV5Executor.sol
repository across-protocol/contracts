// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

interface IAcrossV5Executor {
    // ── Errors ───────────────────────────────────────────────────────────
    error OnlyGateway();
    error OnlySelf();
    error LengthMismatch();
    error ExecutionFailed(uint256 commandIndex, bytes message);
    error InvalidCommandType(uint256 commandType);
    error NotImplemented(uint256 commandType);
    error BalanceRequirementNotMet(address token, uint256 required, uint256 actual);
    error DeadlineExceeded(uint256 deadline, uint256 current);
    error NotYetValid(uint256 validAfter, uint256 current);
    error SubmitterMismatch(address required, address actual);
    error CallFailed(address target, bytes revertData);
    error CalldataTooShort(uint256 callDataLength, uint256 offset);
    error NativeTransferFailed();
    error InvalidAmountEncoding(uint256 encodedAmount);
    error InvalidAmountBips(uint256 bips);

    // ── Functions ────────────────────────────────────────────────────────

    /// @notice Execute a path's command sequence.
    /// @param message         The path message — encodes (bytes commands, bytes[] inputs).
    /// @param executorMessage Submitter-provided dynamic data.
    function executeAcrossV5(bytes calldata message, bytes calldata executorMessage) external payable;
}
