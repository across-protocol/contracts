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
     * @param routeParams ABI-encoded user-committed route parameters.
     * @param executionParams ABI-encoded user-committed execution parameters.
     * @param submitterParams ABI-encoded runtime submitter parameters.
     */
    function execute(
        bytes calldata routeParams,
        bytes calldata executionParams,
        bytes calldata submitterParams
    ) external payable;
}
