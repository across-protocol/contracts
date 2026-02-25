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

    function execute(address depositAddress, bytes calldata executeCalldata) public payable {
        _execute(depositAddress, executeCalldata);
    }

    function deployAndExecute(
        address counterfactualDepositImplementation,
        bytes32 paramsHash,
        bytes32 salt,
        bytes calldata executeCalldata
    ) external payable returns (address depositAddress) {
        depositAddress = deploy(counterfactualDepositImplementation, paramsHash, salt);
        _execute(depositAddress, executeCalldata);
    }

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

    function _execute(address depositAddress, bytes calldata executeCalldata) internal {
        (bool success, bytes memory returnData) = depositAddress.call{ value: msg.value }(executeCalldata);
        if (!success) {
            assembly {
                revert(add(returnData, 32), mload(returnData))
            }
        }
    }
}
