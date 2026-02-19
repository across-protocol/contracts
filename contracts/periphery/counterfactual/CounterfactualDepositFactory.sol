// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { ICounterfactualDepositFactory } from "../../interfaces/ICounterfactualDepositFactory.sol";

/**
 * @title CounterfactualDepositFactory
 * @notice Generic factory for deploying counterfactual deposit addresses via CREATE2
 * @dev Bridge-agnostic: takes a pre-computed paramsHash and stores it in the clone's immutable args.
 *      Each implementation defines its own immutables struct. The caller hashes the params off-chain.
 */
contract CounterfactualDepositFactory is ICounterfactualDepositFactory {
    /**
     * @notice Deploys a counterfactual deposit contract
     * @param counterfactualDepositImplementation Implementation contract address
     * @param paramsHash keccak256 hash of the ABI-encoded route parameters
     * @param salt Unique salt for address generation
     * @return depositAddress Address of deployed contract
     */
    function deploy(
        address counterfactualDepositImplementation,
        bytes32 paramsHash,
        bytes32 salt
    ) public returns (address depositAddress) {
        depositAddress = Clones.cloneDeterministicWithImmutableArgs(
            counterfactualDepositImplementation,
            abi.encode(paramsHash),
            salt
        );
        emit DepositAddressCreated(depositAddress, counterfactualDepositImplementation, paramsHash, salt);
    }

    /**
     * @notice Forwards calldata to a deployed clone, bubbling up any revert
     * @param depositAddress Address of the deployed clone
     * @param executeCalldata Calldata to forward (e.g. abi.encodeCall of executeDeposit)
     */
    function execute(address depositAddress, bytes calldata executeCalldata) public payable {
        _execute(depositAddress, executeCalldata);
    }

    /**
     * @notice Deploys and executes a deposit in one transaction
     * @dev Reverts if the clone is already deployed. Use deployIfNeededAndExecute for idempotent behavior.
     * @param counterfactualDepositImplementation Implementation contract address
     * @param paramsHash keccak256 hash of the ABI-encoded route parameters
     * @param salt Unique salt for address generation
     * @param executeCalldata Calldata to forward to the clone (e.g. abi.encodeCall of executeDeposit)
     * @return depositAddress Address of deposit contract
     */
    function deployAndExecute(
        address counterfactualDepositImplementation,
        bytes32 paramsHash,
        bytes32 salt,
        bytes calldata executeCalldata
    ) external payable returns (address depositAddress) {
        depositAddress = deploy(counterfactualDepositImplementation, paramsHash, salt);
        _execute(depositAddress, executeCalldata);
    }

    /**
     * @notice Deploys (if not already deployed) and executes a deposit in one transaction
     * @dev Unlike deployAndExecute, this does not revert if the clone already exists.
     * @param counterfactualDepositImplementation Implementation contract address
     * @param paramsHash keccak256 hash of the ABI-encoded route parameters
     * @param salt Unique salt for address generation
     * @param executeCalldata Calldata to forward to the clone (e.g. abi.encodeCall of executeDeposit)
     * @return depositAddress Address of deposit contract
     */
    function deployIfNeededAndExecute(
        address counterfactualDepositImplementation,
        bytes32 paramsHash,
        bytes32 salt,
        bytes calldata executeCalldata
    ) external payable returns (address depositAddress) {
        depositAddress = predictDepositAddress(counterfactualDepositImplementation, paramsHash, salt);
        if (depositAddress.code.length == 0) deploy(counterfactualDepositImplementation, paramsHash, salt);
        _execute(depositAddress, executeCalldata);
    }

    /**
     * @notice Predicts the address of a counterfactual deposit contract
     * @param counterfactualDepositImplementation Implementation contract address
     * @param paramsHash keccak256 hash of the ABI-encoded route parameters
     * @param salt Unique salt for address generation
     * @return Predicted address
     */
    function predictDepositAddress(
        address counterfactualDepositImplementation,
        bytes32 paramsHash,
        bytes32 salt
    ) public view returns (address) {
        return
            Clones.predictDeterministicAddressWithImmutableArgs(
                counterfactualDepositImplementation,
                abi.encode(paramsHash),
                salt
            );
    }

    /// @dev Forwards calldata to a clone, bubbling up any revert.
    function _execute(address depositAddress, bytes calldata executeCalldata) internal {
        (bool success, bytes memory returnData) = depositAddress.call{ value: msg.value }(executeCalldata);
        if (!success) {
            assembly {
                revert(add(returnData, 32), mload(returnData))
            }
        }
    }
}
