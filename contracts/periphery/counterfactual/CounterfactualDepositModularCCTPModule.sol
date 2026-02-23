// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { CounterfactualDepositCCTPModule, CCTPRoute } from "./CounterfactualDepositCCTP.sol";
import { ICounterfactualDepositRouteModule } from "../../interfaces/ICounterfactualDepositRouteModule.sol";

/// @notice User-committed guardrails for modular CCTP execution.
struct CCTPUserParams {
    CCTPRoute route;
    uint256 maxAmount;
    uint256 maxCctpDeadline;
}

/// @notice Runtime submitter arguments for modular CCTP execution.
struct CCTPSubmitterParams {
    uint256 amount;
    address executionFeeRecipient;
    bytes32 nonce;
    uint256 cctpDeadline;
    bytes signature;
}

/**
 * @title CounterfactualDepositModularCCTPModule
 * @notice Delegatecall module for CCTP route execution.
 */
contract CounterfactualDepositModularCCTPModule is CounterfactualDepositCCTPModule, ICounterfactualDepositRouteModule {
    error GuardrailViolation();

    constructor(
        address _srcPeriphery,
        uint32 _sourceDomain
    ) CounterfactualDepositCCTPModule(_srcPeriphery, _sourceDomain) {}

    /**
     * @inheritdoc ICounterfactualDepositRouteModule
     */
    function execute(bytes calldata guardrailParams, bytes calldata submitterParams) external payable {
        CCTPUserParams memory user = abi.decode(guardrailParams, (CCTPUserParams));
        CCTPSubmitterParams memory submitter = abi.decode(submitterParams, (CCTPSubmitterParams));

        if (submitter.amount > user.maxAmount || submitter.cctpDeadline > user.maxCctpDeadline) {
            revert GuardrailViolation();
        }

        _executeCCTPRouteMemory(
            user.route,
            submitter.amount,
            submitter.executionFeeRecipient,
            submitter.nonce,
            submitter.cctpDeadline,
            submitter.signature
        );
    }
}
