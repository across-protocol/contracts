// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { CounterfactualDepositBase, CounterfactualDepositGlobalConfig } from "./CounterfactualDepositBase.sol";
import { ICounterfactualDepositRouteModule } from "../../interfaces/ICounterfactualDepositRouteModule.sol";

/**
 * @title CounterfactualDepositMultiBridgeModular
 * @notice Generic merkle-routed counterfactual dispatcher with delegatecall-based bridge modules.
 * @dev Clone immutables commit to `keccak256(abi.encode(CounterfactualDepositGlobalConfig))`.
 *      Route leaf format is `keccak256(abi.encode(moduleImplementation, keccak256(guardrailParams)))`.
 */
contract CounterfactualDepositMultiBridgeModular is CounterfactualDepositBase {
    event ModuleExecuted(address indexed implementation, bytes32 indexed guardrailHash);

    receive() external payable {}

    /**
     * @notice Computes the merkle leaf for a module route commitment.
     * @param implementation Module implementation address that will be delegatecalled.
     * @param guardrailHash keccak256 hash of the ABI-encoded user guardrail params.
     */
    function computeRouteLeaf(address implementation, bytes32 guardrailHash) public pure returns (bytes32) {
        return keccak256(abi.encode(implementation, guardrailHash));
    }

    /**
     * @notice Convenience helper to compute route leaf from raw guardrail params.
     * @param implementation Module implementation address that will be delegatecalled.
     * @param guardrailParams ABI-encoded user guardrail params.
     */
    function computeRouteLeafFromParams(
        address implementation,
        bytes calldata guardrailParams
    ) external pure returns (bytes32) {
        return computeRouteLeaf(implementation, keccak256(guardrailParams));
    }

    /**
     * @notice Executes a route through a delegatecall module after merkle proof verification.
     * @param globalConfig Clone-level config committed in the clone args hash.
     * @param implementation Route module implementation address.
     * @param guardrailParams ABI-encoded user-committed guardrails.
     * @param submitterParams ABI-encoded runtime submitter params.
     * @param proof Merkle proof proving `(implementation, keccak256(guardrailParams))`.
     */
    function execute(
        CounterfactualDepositGlobalConfig memory globalConfig,
        address implementation,
        bytes calldata guardrailParams,
        bytes calldata submitterParams,
        bytes32[] calldata proof
    ) external payable verifyParamsHash(keccak256(abi.encode(globalConfig))) {
        if (implementation.code.length == 0) revert InvalidModuleImplementation();

        bytes32 guardrailHash = keccak256(guardrailParams);
        _verifyRoute(globalConfig, computeRouteLeaf(implementation, guardrailHash), proof);
        _delegateExecute(implementation, guardrailParams, submitterParams);

        emit ModuleExecuted(implementation, guardrailHash);
    }

    /**
     * @dev Performs delegatecall to a route module and bubbles up revert data.
     */
    function _delegateExecute(
        address implementation,
        bytes calldata guardrailParams,
        bytes calldata submitterParams
    ) internal {
        (bool success, bytes memory returnData) = implementation.delegatecall(
            abi.encodeWithSelector(ICounterfactualDepositRouteModule.execute.selector, guardrailParams, submitterParams)
        );
        if (!success) {
            assembly {
                revert(add(returnData, 32), mload(returnData))
            }
        }
    }
}
