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
     * @param routeParams ABI-encoded route commitment payload.
     * @param executionParams ABI-encoded runtime execution parameters.
     */
    function execute(bytes calldata routeParams, bytes calldata executionParams) external payable;
}
