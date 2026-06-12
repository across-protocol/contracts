// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { CloneArgs } from "../periphery/counterfactual/CounterfactualCloneArgs.sol";

/**
 * @title ICounterfactualDepositFactory
 * @notice Interface for the counterfactual deposit factory.
 * @dev Deploys clones of the `CounterfactualDeposit` dispatcher with a 32-byte `argsHash`
 *      (over `CloneArgs`) as the immutable args blob. The five identity fields are passed
 *      in clear at the API; the factory hashes them internally.
 * @custom:security-contact bugs@across.to
 */
interface ICounterfactualDepositFactory {
    /// @notice Emitted when a new clone is deployed.
    event DepositAddressCreated(
        address indexed depositAddress,
        address indexed dispatcher,
        bytes32 indexed argsHash,
        CloneArgs cloneArgs,
        bytes32 salt
    );

    /**
     * @notice Predicts the deterministic address of a clone before deployment.
     * @param dispatcher `CounterfactualDeposit` dispatcher address (EIP-1167 target).
     * @param cloneArgs The five identity fields the clone is keyed to.
     * @param salt Unique salt for address generation.
     */
    function predictDepositAddress(
        address dispatcher,
        CloneArgs calldata cloneArgs,
        bytes32 salt
    ) external view returns (address);

    /**
     * @notice Deploys a counterfactual deposit clone via CREATE2.
     * @param dispatcher `CounterfactualDeposit` dispatcher address (EIP-1167 target).
     * @param cloneArgs The five identity fields the clone is keyed to.
     * @param salt Unique salt for address generation.
     * @return depositAddress Address of deployed clone.
     */
    function deploy(
        address dispatcher,
        CloneArgs calldata cloneArgs,
        bytes32 salt
    ) external returns (address depositAddress);

    /**
     * @notice Forwards calldata to a deployed clone.
     * @param depositAddress Address of the deployed clone.
     * @param executeCalldata Calldata to forward (e.g. `abi.encodeCall` of `ICounterfactualDeposit.execute`).
     */
    function execute(address depositAddress, bytes calldata executeCalldata) external payable;

    /**
     * @notice Deploys and executes against a clone in one transaction. Reverts if already deployed.
     * @param dispatcher `CounterfactualDeposit` dispatcher address (EIP-1167 target).
     * @param cloneArgs The five identity fields the clone is keyed to.
     * @param salt Unique salt for address generation.
     * @param executeCalldata Calldata to forward to the clone.
     */
    function deployAndExecute(
        address dispatcher,
        CloneArgs calldata cloneArgs,
        bytes32 salt,
        bytes calldata executeCalldata
    ) external payable returns (address depositAddress);

    /**
     * @notice Deploys (if not yet deployed) and executes against a clone in one transaction.
     * @param dispatcher `CounterfactualDeposit` dispatcher address (EIP-1167 target).
     * @param cloneArgs The five identity fields the clone is keyed to.
     * @param salt Unique salt for address generation.
     * @param executeCalldata Calldata to forward to the clone.
     */
    function deployIfNeededAndExecute(
        address dispatcher,
        CloneArgs calldata cloneArgs,
        bytes32 salt,
        bytes calldata executeCalldata
    ) external payable returns (address depositAddress);
}
