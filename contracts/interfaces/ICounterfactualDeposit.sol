// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

/**
 * @title ICounterfactualDeposit
 * @notice Shared errors and events for the counterfactual deposit system
 */
interface ICounterfactualDeposit {
    /// @dev Caller is not the authorized withdraw address.
    error Unauthorized();
    /// @dev Clone's token balance is less than the requested deposit amount.
    error InsufficientBalance();
    /// @dev Caller-supplied params do not match the hash stored in the clone's immutable args.
    error InvalidParamsHash();
    /// @dev Total fee (relayer + execution) exceeds maxFeeBps. SpokePool only.
    error MaxFee();
    /// @dev EIP-712 signature does not recover to the expected signer. SpokePool only.
    error InvalidSignature();

    /// @param depositAddress The clone address that executed the deposit.
    /// @param amount Net amount deposited (after executionFee deduction).
    /// @param nonce Protocol-specific nonce (bytes32(0) for SpokePool which has no nonce).
    event DepositExecuted(address indexed depositAddress, uint256 amount, bytes32 nonce);
    event AdminWithdraw(address indexed depositAddress, address indexed token, address indexed to, uint256 amount);
    event UserWithdraw(address indexed depositAddress, address indexed token, address indexed to, uint256 amount);
}
