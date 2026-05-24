// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { ICounterfactualDeposit } from "../../interfaces/ICounterfactualDeposit.sol";
import { ICounterfactualDepositFactory } from "../../interfaces/ICounterfactualDepositFactory.sol";

/**
 * @title CounterfactualDepositFactory
 * @notice Factory for deploying counterfactual deposit clones via CREATE2.
 * @dev The factory deploys clones of the `CounterfactualDeposit` dispatcher (passed in at construction).
 *      Clone identity is `keccak256(abi.encode(recipient, dstChainId, outputToken))`; the genesis
 *      operational root is folded into the CREATE2 salt so a different `initialRoot` produces a
 *      different address. Deploy is permissionless — front-running with a malicious root cannot
 *      collide with an honest user's predicted address.
 * @custom:security-contact bugs@across.to
 */
contract CounterfactualDepositFactory is ICounterfactualDepositFactory {
    /// @notice The dispatcher contract that every clone proxies into.
    address public immutable dispatcher;

    constructor(address _dispatcher) {
        dispatcher = _dispatcher;
    }

    /// @inheritdoc ICounterfactualDepositFactory
    function deploy(bytes32 identityHash, bytes32 initialRoot) public returns (address depositAddress) {
        bytes32 salt = keccak256(abi.encode(identityHash, initialRoot));
        depositAddress = Clones.cloneDeterministic(dispatcher, salt);
        ICounterfactualDeposit(payable(depositAddress)).initialize(initialRoot);
        emit DepositAddressCreated(depositAddress, identityHash, initialRoot);
    }

    /// @inheritdoc ICounterfactualDepositFactory
    function execute(address depositAddress, bytes calldata executeCalldata) external payable {
        _execute(depositAddress, executeCalldata);
    }

    /// @inheritdoc ICounterfactualDepositFactory
    function deployAndExecute(
        bytes32 identityHash,
        bytes32 initialRoot,
        bytes calldata executeCalldata
    ) external payable returns (address depositAddress) {
        depositAddress = deploy(identityHash, initialRoot);
        _execute(depositAddress, executeCalldata);
    }

    /// @inheritdoc ICounterfactualDepositFactory
    function deployIfNeededAndExecute(
        bytes32 identityHash,
        bytes32 initialRoot,
        bytes calldata executeCalldata
    ) external payable returns (address depositAddress) {
        depositAddress = predictDepositAddress(identityHash, initialRoot);
        if (depositAddress.code.length == 0) deploy(identityHash, initialRoot);
        _execute(depositAddress, executeCalldata);
    }

    /// @inheritdoc ICounterfactualDepositFactory
    function deployAndMigrateAndExecute(
        bytes32 identityHash,
        bytes32 initialRoot,
        bytes32 newOperationalRoot,
        bytes32[] calldata migrateProof,
        bytes calldata executeCalldata
    ) external payable returns (address depositAddress) {
        depositAddress = predictDepositAddress(identityHash, initialRoot);
        if (depositAddress.code.length == 0) deploy(identityHash, initialRoot);
        // Skip migrate if the clone is already at the target root (e.g., genesis root already matches).
        if (ICounterfactualDeposit(payable(depositAddress)).merkleRoot() != newOperationalRoot) {
            ICounterfactualDeposit(payable(depositAddress)).migrate(newOperationalRoot, migrateProof);
        }
        _execute(depositAddress, executeCalldata);
    }

    /// @inheritdoc ICounterfactualDepositFactory
    function predictDepositAddress(bytes32 identityHash, bytes32 initialRoot) public view virtual returns (address) {
        bytes32 salt = keccak256(abi.encode(identityHash, initialRoot));
        return Clones.predictDeterministicAddress(dispatcher, salt);
    }

    /**
     * @dev Forwards calldata to a clone, bubbling up any revert.
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
