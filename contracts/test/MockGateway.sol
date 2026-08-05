//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

/**
 * @title MockGateway
 * @notice Minimal IGateway stand-in for tests. Exposes settable execution-context fields so a SpokePool wired
 * to this gateway can exercise its V5 deposit/fill paths. The auto-generated getters for the public state
 * variables match the IGateway view selectors that SpokePool calls. On the real Gateway, `currentExecutor` is
 * populated only for the duration of the committed executor's call (zero while idle and during the funding
 * loop), while the other fields are live for the whole execution.
 */
contract MockGateway {
    address public currentSubmitter;
    address public currentExecutor;
    bytes32 public currentStepId;
    bytes32 public currentPathId;

    function setSubmitter(address submitter) external {
        currentSubmitter = submitter;
    }

    function setExecutor(address executor) external {
        currentExecutor = executor;
    }

    function setStepId(bytes32 stepId) external {
        currentStepId = stepId;
    }

    function setPathId(bytes32 pathId) external {
        currentPathId = pathId;
    }
}
