// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

/**
 * @title ICounterfactualDeposit
 * @notice Shared errors and events for the counterfactual deposit system
 */
interface ICounterfactualDeposit {
    /// @dev Caller is not the authorized withdraw address.
    error Unauthorized();
    /// @dev Caller-supplied params do not match the hash stored in the clone's immutable args.
    error InvalidParamsHash();
    /// @dev Total fee (relayer + execution) exceeds maxFeeBps. SpokePool only.
    error MaxFee();
    /// @dev EIP-712 signature does not recover to the expected signer. SpokePool only.
    error InvalidSignature();
    /// @dev Native ETH transfer failed.
    error NativeTransferFailed();
    /// @dev EIP-712 signature deadline has passed. SpokePool only.
    error SignatureExpired();

    event CounterfactualDepositExecuted(
        uint256 amount,
        bytes32 nonce,
        address executionFeeRecipient,
        uint256 executionFee
    );
    event AdminWithdraw(address indexed token, address indexed to, uint256 amount);
    event UserWithdraw(address indexed token, address indexed to, uint256 amount);
}
