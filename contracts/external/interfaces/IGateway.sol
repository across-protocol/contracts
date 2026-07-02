// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

/**
 * @notice Read-only subset of the Across V5 Gateway interface: the live execution-context getters the SpokePool
 * needs to authenticate and parameterize V5 fills. The canonical, full interface lives in the Across V5
 * periphery repository. All getters are backed by transient storage on the Gateway and return zero values when
 * no execution is in flight.
 */
interface IGateway {
    /// @notice Active step id (the Merkle root) for the currently executing step, or bytes32(0) when idle.
    function currentStepId() external view returns (bytes32);

    /// @notice Active path id (the path's Merkle leaf hash) for the currently executing step, or bytes32(0) when idle.
    function currentPathId() external view returns (bytes32);

    /// @notice Active submitter (the `execute()` caller) for the currently executing step, or address(0) when idle.
    function currentSubmitter() external view returns (address);

    /// @notice The committed executor of the currently executing step, or address(0) when no executor call is in
    /// flight. The Gateway sets this immediately before calling the committed executor and clears it right after
    /// the call returns — so it reads zero while idle AND while the uncommitted funding loop runs. That is what
    /// makes `msg.sender == currentExecutor()` the complete funding-adapter boundary check.
    function currentExecutor() external view returns (address);
}
