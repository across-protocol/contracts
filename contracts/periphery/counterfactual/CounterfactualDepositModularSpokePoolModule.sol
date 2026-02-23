// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { CounterfactualDepositSpokePoolModule, SpokePoolRoute } from "./CounterfactualDepositSpokePool.sol";
import { ICounterfactualDepositRouteModule } from "../../interfaces/ICounterfactualDepositRouteModule.sol";

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
    constructor(
        address _spokePool,
        address _signer,
        address _wrappedNativeToken
    ) CounterfactualDepositSpokePoolModule(_spokePool, _signer, _wrappedNativeToken) {}

    /**
     * @inheritdoc ICounterfactualDepositRouteModule
     */
    function execute(bytes calldata guardrailParams, bytes calldata submitterParams) external payable {
        SpokePoolRoute memory route = abi.decode(guardrailParams, (SpokePoolRoute));
        SpokePoolSubmitterParams memory submitter = abi.decode(submitterParams, (SpokePoolSubmitterParams));

        _executeSpokePoolRouteMemory(
            route,
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
