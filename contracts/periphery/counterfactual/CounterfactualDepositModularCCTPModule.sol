// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { CounterfactualDepositCCTPModule, CCTPRoute } from "./CounterfactualDepositCCTP.sol";
import { ICounterfactualDepositRouteModule } from "../../interfaces/ICounterfactualDepositRouteModule.sol";

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
    constructor(
        address _srcPeriphery,
        uint32 _sourceDomain
    ) CounterfactualDepositCCTPModule(_srcPeriphery, _sourceDomain) {}

    /**
     * @inheritdoc ICounterfactualDepositRouteModule
     */
    function execute(bytes calldata guardrailParams, bytes calldata submitterParams) external payable {
        CCTPRoute memory route = abi.decode(guardrailParams, (CCTPRoute));
        CCTPSubmitterParams memory submitter = abi.decode(submitterParams, (CCTPSubmitterParams));
        _executeCCTPRouteMemory(
            route,
            submitter.amount,
            submitter.executionFeeRecipient,
            submitter.nonce,
            submitter.cctpDeadline,
            submitter.signature
        );
    }
}
