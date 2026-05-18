// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

/**
 * @title ICounterfactualDepositFactory
 * @notice Interface for the generic counterfactual deposit factory
 * @dev This factory creates reusable deposit addresses via CREATE2. It is bridge-agnostic:
 *      each implementation defines its own params struct, and the factory stores only the merkle root
 *      in the clone's immutable args. The merkle root commits to every leaf's full params (including
 *      destination), so the destination identity is cryptographically bound into the CREATE2 address.
 * @custom:security-contact bugs@across.to
 */
interface ICounterfactualDepositFactory {
    /// @notice Emitted when a new clone is deployed.
    event DepositAddressCreated(
        address indexed depositAddress,
        address indexed counterfactualDepositImplementation,
        bytes32 indexed merkleRoot,
        bytes32 salt
    );

    /**
     * @notice Predicts the deterministic address of a clone before deployment.
     * @param counterfactualDepositImplementation Implementation contract address.
     * @param merkleRoot Root of the leaf tree authorizing the clone's executable actions.
     * @param salt Unique salt for address generation.
     * @return Predicted address.
     */
    function predictDepositAddress(
        address counterfactualDepositImplementation,
        bytes32 merkleRoot,
        bytes32 salt
    ) external view returns (address);

    /**
     * @notice Deploys a counterfactual deposit clone via CREATE2.
     * @param counterfactualDepositImplementation Implementation contract address.
     * @param merkleRoot Root of the leaf tree authorizing the clone's executable actions.
     * @param salt Unique salt for address generation.
     * @return depositAddress Address of deployed clone.
     */
    function deploy(
        address counterfactualDepositImplementation,
        bytes32 merkleRoot,
        bytes32 salt
    ) external returns (address depositAddress);

    /**
     * @notice Forwards calldata to a deployed clone.
     * @param depositAddress Address of the deployed clone.
     * @param executeCalldata Calldata to forward (e.g. abi.encodeCall of executeDeposit).
     */
    function execute(address depositAddress, bytes calldata executeCalldata) external payable;

    /**
     * @notice Deploys and executes a deposit in one transaction.
     * @param counterfactualDepositImplementation Implementation contract address.
     * @param merkleRoot Root of the leaf tree authorizing the clone's executable actions.
     * @param salt Unique salt for address generation.
     * @param executeCalldata Calldata to forward to the clone.
     * @return depositAddress Address of deployed clone.
     */
    function deployAndExecute(
        address counterfactualDepositImplementation,
        bytes32 merkleRoot,
        bytes32 salt,
        bytes calldata executeCalldata
    ) external payable returns (address depositAddress);

    /**
     * @notice Deploys (if needed) and executes a deposit in one transaction.
     * @param counterfactualDepositImplementation Implementation contract address.
     * @param merkleRoot Root of the leaf tree authorizing the clone's executable actions.
     * @param salt Unique salt for address generation.
     * @param executeCalldata Calldata to forward to the clone.
     * @return depositAddress Address of deployed clone.
     */
    function deployIfNeededAndExecute(
        address counterfactualDepositImplementation,
        bytes32 merkleRoot,
        bytes32 salt,
        bytes calldata executeCalldata
    ) external payable returns (address depositAddress);
}
