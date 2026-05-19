// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { ICounterfactualDepositFactory } from "../../interfaces/ICounterfactualDepositFactory.sol";
import { CloneArgs, CounterfactualCloneArgs } from "./CounterfactualCloneArgs.sol";

/**
 * @title CounterfactualDepositFactory
 * @notice Deploys deterministic clones of the `CounterfactualDeposit` dispatcher via CREATE2.
 * @dev The user-facing API accepts the five identity fields (`CloneArgs`); internally the factory
 *      computes `argsHash = CounterfactualCloneArgs.hash(cloneArgs)` and uses that 32-byte hash as
 *      the clone's immutable-args blob.
 * @custom:security-contact bugs@across.to
 */
contract CounterfactualDepositFactory is ICounterfactualDepositFactory {
    using CounterfactualCloneArgs for CloneArgs;

    /// @inheritdoc ICounterfactualDepositFactory
    function deploy(
        address dispatcher,
        CloneArgs calldata cloneArgs,
        bytes32 salt
    ) public returns (address depositAddress) {
        bytes32 argsHash = cloneArgs.hash();
        depositAddress = Clones.cloneDeterministicWithImmutableArgs(dispatcher, abi.encode(argsHash), salt);
        emit DepositAddressCreated(depositAddress, dispatcher, argsHash, cloneArgs, salt);
    }

    /// @inheritdoc ICounterfactualDepositFactory
    function execute(address depositAddress, bytes calldata executeCalldata) external payable {
        _execute(depositAddress, executeCalldata);
    }

    /// @inheritdoc ICounterfactualDepositFactory
    function deployAndExecute(
        address dispatcher,
        CloneArgs calldata cloneArgs,
        bytes32 salt,
        bytes calldata executeCalldata
    ) external payable returns (address depositAddress) {
        depositAddress = deploy(dispatcher, cloneArgs, salt);
        _execute(depositAddress, executeCalldata);
    }

    /// @inheritdoc ICounterfactualDepositFactory
    function deployIfNeededAndExecute(
        address dispatcher,
        CloneArgs calldata cloneArgs,
        bytes32 salt,
        bytes calldata executeCalldata
    ) external payable returns (address depositAddress) {
        depositAddress = predictDepositAddress(dispatcher, cloneArgs, salt);
        if (depositAddress.code.length == 0) deploy(dispatcher, cloneArgs, salt);
        _execute(depositAddress, executeCalldata);
    }

    /// @inheritdoc ICounterfactualDepositFactory
    function predictDepositAddress(
        address dispatcher,
        CloneArgs calldata cloneArgs,
        bytes32 salt
    ) public view virtual returns (address) {
        return Clones.predictDeterministicAddressWithImmutableArgs(dispatcher, abi.encode(cloneArgs.hash()), salt);
    }

    /// @dev Forwards calldata to a clone, bubbling up any revert.
    function _execute(address depositAddress, bytes calldata executeCalldata) private {
        (bool success, bytes memory returnData) = depositAddress.call{ value: msg.value }(executeCalldata);
        if (!success) {
            assembly {
                revert(add(returnData, 32), mload(returnData))
            }
        }
    }
}
