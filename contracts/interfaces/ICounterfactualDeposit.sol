// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

/**
 * @title ICounterfactualDeposit
 * @notice Shared errors and events for the counterfactual deposit system
 */
interface ICounterfactualDeposit {
    error Unauthorized();
    error InsufficientBalance();
    error InvalidParamsHash();
    error MaxFee();
    error InvalidSignature();

    event DepositExecuted(address indexed depositAddress, uint256 amount, bytes32 nonce);
    event AdminWithdraw(address indexed depositAddress, address indexed token, address indexed to, uint256 amount);
    event UserWithdraw(address indexed depositAddress, address indexed token, address indexed to, uint256 amount);
}
