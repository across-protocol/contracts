// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { CounterfactualDepositSpokePoolModule, SpokePoolRoute } from "./CounterfactualDepositSpokePool.sol";
import { ICounterfactualDepositRouteModule } from "../../interfaces/ICounterfactualDepositRouteModule.sol";

/// @notice User-committed guardrails for modular SpokePool execution.
struct SpokePoolUserParams {
    SpokePoolRoute route;
    uint256 maxInputAmount;
    uint256 minOutputAmount;
    uint32 maxFillDeadline;
    uint32 maxSignatureDeadline;
}

/// @notice Runtime submitter arguments for modular SpokePool execution.
struct SpokePoolSubmitterParams {
    uint256 inputAmount;
    uint256 outputAmount;
    bytes32 exclusiveRelayer;
    uint32 exclusivityDeadline;
    address executionFeeRecipient;
    uint32 quoteTimestamp;
    uint32 fillDeadline;
    uint32 signatureDeadline;
    bytes signature;
}

/**
 * @title CounterfactualDepositModularSpokePoolModule
 * @notice Delegatecall module for SpokePool route execution.
 */
contract CounterfactualDepositModularSpokePoolModule is
    CounterfactualDepositSpokePoolModule,
    ICounterfactualDepositRouteModule
{
    error GuardrailViolation();

    constructor(
        address _spokePool,
        address _signer,
        address _wrappedNativeToken
    ) CounterfactualDepositSpokePoolModule(_spokePool, _signer, _wrappedNativeToken) {}

    /**
     * @inheritdoc ICounterfactualDepositRouteModule
     */
    function execute(bytes calldata guardrailParams, bytes calldata submitterParams) external payable {
        SpokePoolUserParams memory user = abi.decode(guardrailParams, (SpokePoolUserParams));
        SpokePoolSubmitterParams memory submitter = abi.decode(submitterParams, (SpokePoolSubmitterParams));

        if (
            submitter.inputAmount > user.maxInputAmount ||
            submitter.outputAmount < user.minOutputAmount ||
            submitter.fillDeadline > user.maxFillDeadline ||
            submitter.signatureDeadline > user.maxSignatureDeadline
        ) revert GuardrailViolation();

        _executeSpokePoolRouteMemory(
            user.route,
            submitter.inputAmount,
            submitter.outputAmount,
            submitter.exclusiveRelayer,
            submitter.exclusivityDeadline,
            submitter.executionFeeRecipient,
            submitter.quoteTimestamp,
            submitter.fillDeadline,
            submitter.signatureDeadline,
            submitter.signature
        );
    }
}
