// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

/**
 * @title ICounterfactualDepositRouteModule
 * @notice Delegatecall module interface for modular counterfactual multi-bridge execution.
 */
interface ICounterfactualDepositRouteModule {
    /**
     * @notice Executes one bridge route.
     * @dev Called by CounterfactualDepositMultiBridgeModular via delegatecall.
     * @param guardrailParams ABI-encoded user-committed guardrails.
     * @param submitterParams ABI-encoded runtime submitter parameters.
     */
    function execute(bytes calldata guardrailParams, bytes calldata submitterParams) external payable;
}
