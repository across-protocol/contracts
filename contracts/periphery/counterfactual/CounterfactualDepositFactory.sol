// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { ICounterfactualDepositFactory } from "../../interfaces/ICounterfactualDepositFactory.sol";

/**
 * @title CounterfactualDepositFactory
 * @notice Generic factory for deploying counterfactual deposit addresses via CREATE2.
 * @dev Bridge-agnostic: the clone's sole immutable arg is the merkle root of the
 *      `(block.chainid, implementation, keccak256(params))` leaf tree the dispatcher verifies proofs against.
 *      Each leaf's `params` encodes the full route (including destination), so the merkle root
 *      cryptographically commits to every destination the clone can bridge to, and therefore the CREATE2
 *      address itself binds the destination identity. A tree containing a leaf for a different destination
 *      would produce a different root and a different address.
 * @custom:security-contact bugs@across.to
 */
contract CounterfactualDepositFactory is ICounterfactualDepositFactory {
    /**
     * @notice Deploys a counterfactual deposit contract.
     * @param counterfactualDepositImplementation Implementation contract address.
     * @param merkleRoot Root of the leaf tree authorizing the clone's executable actions.
     * @param salt Unique salt for address generation.
     * @return depositAddress Address of deployed contract.
     */
    function deploy(
        address counterfactualDepositImplementation,
        bytes32 merkleRoot,
        bytes32 salt
    ) public returns (address depositAddress) {
        depositAddress = Clones.cloneDeterministicWithImmutableArgs(
            counterfactualDepositImplementation,
            abi.encode(merkleRoot),
            salt
        );
        emit DepositAddressCreated(depositAddress, counterfactualDepositImplementation, merkleRoot, salt);
    }

    /**
     * @notice Forwards calldata to a deployed clone, bubbling up any revert.
     * @param depositAddress Address of the deployed clone.
     * @param executeCalldata Calldata to forward (e.g. abi.encodeCall of executeDeposit).
     */
    function execute(address depositAddress, bytes calldata executeCalldata) external payable {
        _execute(depositAddress, executeCalldata);
    }

    /**
     * @notice Deploys and executes a deposit in one transaction.
     * @dev Reverts if the clone is already deployed. Use deployIfNeededAndExecute for idempotent behavior.
     * @param counterfactualDepositImplementation Implementation contract address.
     * @param merkleRoot Root of the leaf tree authorizing the clone's executable actions.
     * @param salt Unique salt for address generation.
     * @param executeCalldata Calldata to forward to the clone (e.g. abi.encodeCall of executeDeposit).
     * @return depositAddress Address of deposit contract.
     */
    function deployAndExecute(
        address counterfactualDepositImplementation,
        bytes32 merkleRoot,
        bytes32 salt,
        bytes calldata executeCalldata
    ) external payable returns (address depositAddress) {
        depositAddress = deploy(counterfactualDepositImplementation, merkleRoot, salt);
        _execute(depositAddress, executeCalldata);
    }

    /**
     * @notice Deploys (if not already deployed) and executes a deposit in one transaction.
     * @dev Unlike deployAndExecute, this does not revert if the clone already exists.
     * @param counterfactualDepositImplementation Implementation contract address.
     * @param merkleRoot Root of the leaf tree authorizing the clone's executable actions.
     * @param salt Unique salt for address generation.
     * @param executeCalldata Calldata to forward to the clone (e.g. abi.encodeCall of executeDeposit).
     * @return depositAddress Address of deposit contract.
     */
    function deployIfNeededAndExecute(
        address counterfactualDepositImplementation,
        bytes32 merkleRoot,
        bytes32 salt,
        bytes calldata executeCalldata
    ) external payable returns (address depositAddress) {
        depositAddress = predictDepositAddress(counterfactualDepositImplementation, merkleRoot, salt);
        if (depositAddress.code.length == 0) {
            deploy(counterfactualDepositImplementation, merkleRoot, salt);
        }
        _execute(depositAddress, executeCalldata);
    }

    /**
     * @notice Predicts the address of a counterfactual deposit contract.
     * @param counterfactualDepositImplementation Implementation contract address.
     * @param merkleRoot Root of the leaf tree authorizing the clone's executable actions.
     * @param salt Unique salt for address generation.
     * @return Predicted address.
     */
    function predictDepositAddress(
        address counterfactualDepositImplementation,
        bytes32 merkleRoot,
        bytes32 salt
    ) public view virtual returns (address) {
        return
            Clones.predictDeterministicAddressWithImmutableArgs(
                counterfactualDepositImplementation,
                abi.encode(merkleRoot),
                salt
            );
    }

    /**
     * @dev Forwards calldata to a clone, bubbling up any revert.
     * @param depositAddress Address of the deployed clone.
     * @param executeCalldata Calldata to forward.
     */
    function _execute(address depositAddress, bytes calldata executeCalldata) private {
        (bool success, bytes memory returnData) = depositAddress.call{ value: msg.value }(executeCalldata);
        if (!success) {
            assembly {
                revert(add(returnData, 32), mload(returnData))
            }
        }
    }
}
