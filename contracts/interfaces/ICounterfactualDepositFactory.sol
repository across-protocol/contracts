// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

/**
 * @title ICounterfactualDepositFactory
 * @notice Interface for the generic counterfactual deposit factory
 * @dev This factory creates reusable deposit addresses via CREATE2. It is bridge-agnostic:
 *      each executor defines its own immutables struct, and the factory only hashes the raw bytes.
 */
interface ICounterfactualDepositFactory {
    event DepositAddressCreated(
        address indexed depositAddress,
        address indexed executor,
        bytes32 indexed paramsHash,
        bytes32 salt
    );

    function predictDepositAddress(
        address executor,
        bytes memory encodedParams,
        bytes32 salt
    ) external view returns (address);

    function deploy(address executor, bytes memory encodedParams, bytes32 salt) external returns (address);

    function deployAndExecute(
        address executor,
        bytes memory encodedParams,
        bytes32 salt,
        bytes calldata executeCalldata
    ) external payable returns (address depositAddress);
}
