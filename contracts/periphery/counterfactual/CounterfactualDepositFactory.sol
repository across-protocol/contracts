// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { ICounterfactualDepositFactory } from "../../interfaces/ICounterfactualDepositFactory.sol";

/**
 * @title CounterfactualDepositFactory
 * @notice Generic factory for deploying counterfactual deposit addresses via CREATE2
 * @dev Bridge-agnostic: takes raw bytes encodedParams and forwards raw calldata to clones.
 *      Each executor defines its own immutables struct. The factory only hashes the bytes.
 */
contract CounterfactualDepositFactory is ICounterfactualDepositFactory {
    /**
     * @notice Predicts the address of a counterfactual deposit contract
     * @param executor Executor implementation address
     * @param encodedParams ABI-encoded route parameters (hashed to produce the clone's immutable arg)
     * @param salt Unique salt for address generation
     * @return Predicted address
     */
    function predictDepositAddress(
        address executor,
        bytes memory encodedParams,
        bytes32 salt
    ) public view returns (address) {
        return
            Clones.predictDeterministicAddressWithImmutableArgs(executor, abi.encode(keccak256(encodedParams)), salt);
    }

    /**
     * @notice Deploys a counterfactual deposit contract
     * @param executor Executor implementation address
     * @param encodedParams ABI-encoded route parameters (hashed to produce the clone's immutable arg)
     * @param salt Unique salt for address generation
     * @return depositAddress Address of deployed contract
     */
    function deploy(
        address executor,
        bytes memory encodedParams,
        bytes32 salt
    ) public returns (address depositAddress) {
        bytes32 paramsHash = keccak256(encodedParams);
        depositAddress = Clones.cloneDeterministicWithImmutableArgs(executor, abi.encode(paramsHash), salt);
        emit DepositAddressCreated(depositAddress, executor, paramsHash, salt);
    }

    /**
     * @notice Deploys (if needed) and executes a deposit in one transaction
     * @param executor Executor implementation address
     * @param encodedParams ABI-encoded route parameters
     * @param salt Unique salt for address generation
     * @param executeCalldata Calldata to forward to the clone (e.g. abi.encodeCall of executeDeposit)
     * @return depositAddress Address of deposit contract
     */
    function deployAndExecute(
        address executor,
        bytes memory encodedParams,
        bytes32 salt,
        bytes calldata executeCalldata
    ) external payable returns (address depositAddress) {
        try this.deploy(executor, encodedParams, salt) returns (address addr) {
            depositAddress = addr;
        } catch {
            depositAddress = predictDepositAddress(executor, encodedParams, salt);
        }
        (bool success, bytes memory returnData) = depositAddress.call{ value: msg.value }(executeCalldata);
        if (!success) {
            assembly {
                revert(add(returnData, 32), mload(returnData))
            }
        }
    }
}
