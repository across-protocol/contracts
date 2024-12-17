// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import { Create2 } from "@openzeppelin/contracts/utils/Create2.sol";
import { Lockable } from "./Lockable.sol";

/**
 * @title Create2Factory
 * @notice Deploys a new contract via create2 at a deterministic address and then atomically initializes the contract
 * @dev Contracts designed to be deployed at deterministic addresses should initialize via a non-constructor
 * initializer to maintain bytecode across different chains.
 * @custom:security-contact bugs@across.to
 */
contract Create2Factory is Lockable {
    /// @notice Emitted when the initialization to a newly deployed contract fails
    error InitializationFailed();

    /**
     * @notice Deploys a new contract via create2 at a deterministic address and then atomically initializes the contract
     * @param amount The amount of ETH to send with the deployment. If this is not zero then the contract must have a payable constructor
     * @param salt The salt to use for the create2 deployment. Must not have been used before for the bytecode
     * @param bytecode The bytecode of the contract to deploy
     * @param initializationCode The initialization code to call on the deployed contract
     */
    function deploy(
        uint256 amount,
        bytes32 salt,
        bytes calldata bytecode,
        bytes calldata initializationCode
    ) external nonReentrant returns (address) {
        address deployedAddress = Create2.deploy(amount, salt, bytecode);
        (bool success, ) = deployedAddress.call(initializationCode);
        if (!success) revert InitializationFailed();
        return deployedAddress;
    }
}
