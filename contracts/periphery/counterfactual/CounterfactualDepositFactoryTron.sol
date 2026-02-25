// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { TronClones } from "./TronClones.sol";
import { ICounterfactualDepositFactory } from "../../interfaces/ICounterfactualDepositFactory.sol";

/**
 * @title CounterfactualDepositFactoryTron
 * @notice Tron-compatible factory for deploying counterfactual deposit addresses via CREATE2.
 * @dev Tron's TVM uses 0x41 instead of 0xff as the CREATE2 address derivation prefix.
 *      OZ Clones deploys correctly (the create2 opcode natively uses 0x41 on Tron), but its
 *      address prediction hardcodes 0xff. This factory uses TronClones for prediction to match.
 *      All other logic is identical to CounterfactualDepositFactory.
 */
contract CounterfactualDepositFactoryTron is ICounterfactualDepositFactory {
    /**
     * @notice Deploys a counterfactual deposit contract via CREATE2.
     * @param counterfactualDepositImplementation Implementation contract address.
     * @param paramsHash keccak256 hash of the ABI-encoded route parameters (stored as the clone's immutable arg).
     * @param salt Unique salt for deterministic address generation.
     * @return depositAddress Address of the deployed clone.
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
     * @notice Forwards calldata to a deployed clone, bubbling up any revert.
     * @param depositAddress Address of the deployed clone.
     * @param executeCalldata Calldata to forward (e.g. abi.encodeCall of execute).
     */
    function execute(address depositAddress, bytes calldata executeCalldata) public payable {
        _execute(depositAddress, executeCalldata);
    }

    /**
     * @notice Deploys and executes a deposit in one transaction.
     * @dev Reverts if the clone is already deployed. Use deployIfNeededAndExecute for idempotent behavior.
     * @param counterfactualDepositImplementation Implementation contract address.
     * @param paramsHash keccak256 hash of the ABI-encoded route parameters.
     * @param salt Unique salt for address generation.
     * @param executeCalldata Calldata to forward to the clone.
     * @return depositAddress Address of the deployed clone.
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
     * @notice Deploys (if not already deployed) and executes a deposit in one transaction.
     * @dev Unlike deployAndExecute, this does not revert if the clone already exists.
     * @param counterfactualDepositImplementation Implementation contract address.
     * @param paramsHash keccak256 hash of the ABI-encoded route parameters.
     * @param salt Unique salt for address generation.
     * @param executeCalldata Calldata to forward to the clone.
     * @return depositAddress Address of the deposit clone.
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
     * @notice Predicts the Tron CREATE2 address of a counterfactual deposit contract.
     * @dev Uses TronClones with the 0x41 prefix instead of OZ's 0xff to match TVM behavior.
     * @param counterfactualDepositImplementation Implementation contract address.
     * @param paramsHash keccak256 hash of the ABI-encoded route parameters.
     * @param salt Unique salt for address generation.
     * @return Predicted address of the clone on Tron.
     */
    function predictDepositAddress(
        address counterfactualDepositImplementation,
        bytes32 paramsHash,
        bytes32 salt
    ) public view returns (address) {
        return
            TronClones.predictDeterministicAddressWithImmutableArgs(
                counterfactualDepositImplementation,
                abi.encode(paramsHash),
                salt
            );
    }

    /**
     * @dev Forwards calldata to a clone, bubbling up any revert.
     * @param depositAddress Address of the deployed clone.
     * @param executeCalldata Calldata to forward.
     */
    function _execute(address depositAddress, bytes calldata executeCalldata) internal {
        (bool success, bytes memory returnData) = depositAddress.call{ value: msg.value }(executeCalldata);
        if (!success) {
            assembly {
                revert(add(returnData, 32), mload(returnData))
            }
        }
    }
}
