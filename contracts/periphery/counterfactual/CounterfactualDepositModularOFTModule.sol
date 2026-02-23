// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { CounterfactualDepositOFTModule, OFTRoute } from "./CounterfactualDepositOFT.sol";
import { ICounterfactualDepositRouteModule } from "../../interfaces/ICounterfactualDepositRouteModule.sol";

/// @notice Runtime arguments for modular OFT execution.
struct OFTExecutionRequest {
    uint256 amount;
    address executionFeeRecipient;
    bytes32 nonce;
    uint256 oftDeadline;
}

/// @notice Runtime submitter arguments for modular OFT execution.
struct OFTSubmitterParams {
    bytes signature;
}

/**
 * @title CounterfactualDepositModularOFTModule
 * @notice Delegatecall module for OFT route execution.
 */
contract CounterfactualDepositModularOFTModule is CounterfactualDepositOFTModule, ICounterfactualDepositRouteModule {
    constructor(address _oftSrcPeriphery, uint32 _srcEid) CounterfactualDepositOFTModule(_oftSrcPeriphery, _srcEid) {}

    /**
     * @inheritdoc ICounterfactualDepositRouteModule
     */
    function execute(
        bytes calldata routeParams,
        bytes calldata executionParams,
        bytes calldata submitterParams
    ) external payable {
        OFTRoute memory route = abi.decode(routeParams, (OFTRoute));
        OFTExecutionRequest memory request = abi.decode(executionParams, (OFTExecutionRequest));
        OFTSubmitterParams memory submitter = abi.decode(submitterParams, (OFTSubmitterParams));
        _executeOFTRouteMemory(
            route,
            request.amount,
            request.executionFeeRecipient,
            request.nonce,
            request.oftDeadline,
            submitter.signature
        );
    }
}
