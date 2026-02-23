// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { CounterfactualDepositSpokePoolModule, SpokePoolRoute } from "./CounterfactualDepositSpokePool.sol";
import { ICounterfactualDepositRouteModule } from "../../interfaces/ICounterfactualDepositRouteModule.sol";

/// @notice Runtime arguments for modular SpokePool execution.
struct SpokePoolExecutionRequest {
    uint256 inputAmount;
    uint256 outputAmount;
    bytes32 exclusiveRelayer;
    uint32 exclusivityDeadline;
    address executionFeeRecipient;
    uint32 quoteTimestamp;
    uint32 fillDeadline;
    uint32 signatureDeadline;
}

/// @notice Runtime submitter arguments for modular SpokePool execution.
struct SpokePoolSubmitterParams {
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
    constructor(
        address _spokePool,
        address _signer,
        address _wrappedNativeToken
    ) CounterfactualDepositSpokePoolModule(_spokePool, _signer, _wrappedNativeToken) {}

    /**
     * @inheritdoc ICounterfactualDepositRouteModule
     */
    function execute(
        bytes calldata routeParams,
        bytes calldata executionParams,
        bytes calldata submitterParams
    ) external payable {
        SpokePoolRoute memory route = abi.decode(routeParams, (SpokePoolRoute));
        SpokePoolExecutionRequest memory request = abi.decode(executionParams, (SpokePoolExecutionRequest));
        SpokePoolSubmitterParams memory submitter = abi.decode(submitterParams, (SpokePoolSubmitterParams));

        _executeSpokePoolRouteMemory(
            route,
            request.inputAmount,
            request.outputAmount,
            request.exclusiveRelayer,
            request.exclusivityDeadline,
            request.executionFeeRecipient,
            request.quoteTimestamp,
            request.fillDeadline,
            request.signatureDeadline,
            submitter.signature
        );
    }
}
