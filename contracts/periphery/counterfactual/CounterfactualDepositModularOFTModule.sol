// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { CounterfactualDepositOFTModule, OFTRoute } from "./CounterfactualDepositOFT.sol";
import { ICounterfactualDepositRouteModule } from "../../interfaces/ICounterfactualDepositRouteModule.sol";

/// @notice User-committed guardrails for modular OFT execution.
struct OFTUserParams {
    OFTRoute route;
    uint256 maxAmount;
    uint256 maxOftDeadline;
}

/// @notice Runtime submitter arguments for modular OFT execution.
struct OFTSubmitterParams {
    uint256 amount;
    address executionFeeRecipient;
    bytes32 nonce;
    uint256 oftDeadline;
    bytes signature;
}

/**
 * @title CounterfactualDepositModularOFTModule
 * @notice Delegatecall module for OFT route execution.
 */
contract CounterfactualDepositModularOFTModule is CounterfactualDepositOFTModule, ICounterfactualDepositRouteModule {
    error GuardrailViolation();

    constructor(address _oftSrcPeriphery, uint32 _srcEid) CounterfactualDepositOFTModule(_oftSrcPeriphery, _srcEid) {}

    /**
     * @inheritdoc ICounterfactualDepositRouteModule
     */
    function execute(bytes calldata guardrailParams, bytes calldata submitterParams) external payable {
        OFTUserParams memory user = abi.decode(guardrailParams, (OFTUserParams));
        OFTSubmitterParams memory submitter = abi.decode(submitterParams, (OFTSubmitterParams));

        if (submitter.amount > user.maxAmount || submitter.oftDeadline > user.maxOftDeadline)
            revert GuardrailViolation();

        _executeOFTRouteMemory(
            user.route,
            submitter.amount,
            submitter.executionFeeRecipient,
            submitter.nonce,
            submitter.oftDeadline,
            submitter.signature
        );
    }
}
