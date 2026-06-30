// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import { Step, FundingEntry, SubmitterInputs } from "../types/Common.sol";

interface IGateway {
    error InvalidMerkleProof();
    error Reentrancy();
    error WrongChain(uint256 expected, uint256 actual);
    error UnknownFundingType(uint8 typ);
    error InvalidCommitmentLevel(uint8 commitmentLevel);
    error SignedTransferAlreadyUsed(bytes32 structHash);
    error SignedTransferExpired(uint256 deadline, uint256 current);
    error InvalidSignedTransferSignature();

    event StepExecuted(bytes32 indexed stepId, bytes32 indexed pathId, address submitter);

    function currentStepId() external view returns (bytes32 stepId_);

    /// @notice Active path id for the currently executing step, or bytes32(0) when idle.
    function currentPathId() external view returns (bytes32 pathId_);

    /// @notice Active submitter for the currently executing step, or address(0) when idle.
    function currentSubmitter() external view returns (address submitter);

    /// @notice Execute a step in one transaction.
    function execute(
        Step step,
        SubmitterInputs calldata submitterInputs,
        FundingEntry[] calldata funding
    ) external payable;
}
