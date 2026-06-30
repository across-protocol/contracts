//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

/**
 * @title MockGateway
 * @notice Minimal IGateway stand-in for tests. Exposes settable `currentSubmitter` and `currentStepId` so a
 * SpokePool wired to this gateway can exercise its V5 fill path. The auto-generated getters for the public state
 * variables match the IGateway view selectors that SpokePool calls.
 */
contract MockGateway {
    address public currentSubmitter;
    bytes32 public currentStepId;

    function setSubmitter(address submitter) external {
        currentSubmitter = submitter;
    }

    function setStepId(bytes32 stepId) external {
        currentStepId = stepId;
    }
}
