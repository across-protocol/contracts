// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { CounterfactualDepositBase, CounterfactualDepositGlobalConfig } from "./CounterfactualDepositBase.sol";
import { ICounterfactualDepositRouteModule } from "../../interfaces/ICounterfactualDepositRouteModule.sol";

/**
 * @title CounterfactualDepositMultiBridgeModular
 * @notice Generic merkle-routed counterfactual dispatcher with delegatecall-based bridge modules.
 * @dev Clone immutables commit to `keccak256(abi.encode(CounterfactualDepositGlobalConfig))`.
 *      Route leaf format is `keccak256(abi.encode(moduleImplementation, keccak256(routeParams)))`.
 */
contract CounterfactualDepositMultiBridgeModular is CounterfactualDepositBase {
    event ModuleExecuted(address indexed implementation, bytes32 indexed routeHash);

    receive() external payable {}

    /**
     * @notice Computes the merkle leaf for a module route commitment.
     * @param implementation Module implementation address that will be delegatecalled.
     * @param routeHash keccak256 hash of the ABI-encoded route params.
     */
    function computeRouteLeaf(address implementation, bytes32 routeHash) public pure returns (bytes32) {
        return keccak256(abi.encode(implementation, routeHash));
    }

    /**
     * @notice Convenience helper to compute `routeHash` from raw route params.
     * @param implementation Module implementation address that will be delegatecalled.
     * @param routeParams ABI-encoded route params.
     */
    function computeRouteLeafFromParams(
        address implementation,
        bytes calldata routeParams
    ) external pure returns (bytes32) {
        return computeRouteLeaf(implementation, keccak256(routeParams));
    }

    /**
     * @notice Executes a route through a delegatecall module after merkle proof verification.
     * @param globalConfig Clone-level config committed in the clone args hash.
     * @param implementation Route module implementation address.
     * @param routeParams ABI-encoded route params (committed via `routeHash`).
     * @param executionParams ABI-encoded runtime execution params for the selected module.
     * @param proof Merkle proof proving `(implementation, keccak256(routeParams))` is committed.
     */
    function execute(
        CounterfactualDepositGlobalConfig memory globalConfig,
        address implementation,
        bytes calldata routeParams,
        bytes calldata executionParams,
        bytes32[] calldata proof
    ) external payable verifyParamsHash(keccak256(abi.encode(globalConfig))) {
        if (implementation.code.length == 0) revert InvalidModuleImplementation();

        bytes32 routeHash = keccak256(routeParams);
        _verifyRoute(globalConfig, computeRouteLeaf(implementation, routeHash), proof);
        _delegateExecute(implementation, routeParams, executionParams);

        emit ModuleExecuted(implementation, routeHash);
    }

    /**
     * @dev Performs delegatecall to a route module and bubbles up revert data.
     */
    function _delegateExecute(
        address implementation,
        bytes calldata routeParams,
        bytes calldata executionParams
    ) internal {
        (bool success, bytes memory returnData) = implementation.delegatecall(
            abi.encodeWithSelector(ICounterfactualDepositRouteModule.execute.selector, routeParams, executionParams)
        );
        if (!success) {
            assembly {
                revert(add(returnData, 32), mload(returnData))
            }
        }
    }
}
