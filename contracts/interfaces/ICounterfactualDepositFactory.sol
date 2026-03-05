// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

/**
 * @title ICounterfactualDepositFactory
 * @notice Interface for the generic counterfactual deposit factory
 * @dev This factory creates reusable deposit addresses via CREATE2. It is bridge-agnostic:
 *      each implementation defines its own immutables struct, and the factory stores only the hash.
 */
interface ICounterfactualDepositFactory {
    /// @notice Emitted when a new clone is deployed.
    event DepositAddressCreated(
        address indexed depositAddress,
        address indexed counterfactualDepositImplementation,
        bytes32 indexed paramsHash,
        bytes32 salt
    );

    /**
     * @notice Predicts the deterministic address of a clone before deployment.
     * @param counterfactualDepositImplementation Implementation contract address.
     * @param paramsHash keccak256 hash of the ABI-encoded route parameters.
     * @param signer Address authorized to sign on behalf of the clone (EIP-1271). Use address(0) if not needed.
     * @param salt Unique salt for address generation.
     * @return Predicted address.
     */
    function predictDepositAddress(
        address counterfactualDepositImplementation,
        bytes32 paramsHash,
        address signer,
        bytes32 salt
    ) external view returns (address);

    /**
     * @notice Deploys a counterfactual deposit clone via CREATE2.
     * @param counterfactualDepositImplementation Implementation contract address.
     * @param paramsHash keccak256 hash of the ABI-encoded route parameters.
     * @param signer Address authorized to sign on behalf of the clone (EIP-1271). Use address(0) if not needed.
     * @param salt Unique salt for address generation.
     * @return depositAddress Address of deployed clone.
     */
    function deploy(
        address counterfactualDepositImplementation,
        bytes32 paramsHash,
        address signer,
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
     * @param paramsHash keccak256 hash of the ABI-encoded route parameters.
     * @param signer Address authorized to sign on behalf of the clone (EIP-1271). Use address(0) if not needed.
     * @param salt Unique salt for address generation.
     * @param executeCalldata Calldata to forward to the clone.
     * @return depositAddress Address of deployed clone.
     */
    function deployAndExecute(
        address counterfactualDepositImplementation,
        bytes32 paramsHash,
        address signer,
        bytes32 salt,
        bytes calldata executeCalldata
    ) external payable returns (address depositAddress);

    /**
     * @notice Deploys (if needed) and executes a deposit in one transaction.
     * @param counterfactualDepositImplementation Implementation contract address.
     * @param paramsHash keccak256 hash of the ABI-encoded route parameters.
     * @param signer Address authorized to sign on behalf of the clone (EIP-1271). Use address(0) if not needed.
     * @param salt Unique salt for address generation.
     * @param executeCalldata Calldata to forward to the clone.
     * @return depositAddress Address of deployed clone.
     */
    function deployIfNeededAndExecute(
        address counterfactualDepositImplementation,
        bytes32 paramsHash,
        address signer,
        bytes32 salt,
        bytes calldata executeCalldata
    ) external payable returns (address depositAddress);
}
