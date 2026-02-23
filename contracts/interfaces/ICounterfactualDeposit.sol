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
    /// @dev Merkle proof does not prove the route is allowed by this clone.
    error InvalidRouteProof();
    /// @dev Route hash does not match the committed hash for this bridge.
    error InvalidRouteHash();
    /// @dev Bridge route is disabled for this clone (committed hash is zero).
    error RouteDisabled();
    /// @dev Selected module implementation has no runtime bytecode.
    error InvalidModuleImplementation();
    /// @dev Total fee (relayer + execution) exceeds maxFeeBps. SpokePool only.
    error MaxFee();
    /// @dev EIP-712 signature does not recover to the expected signer. SpokePool only.
    error InvalidSignature();
    /// @dev Native ETH transfer failed.
    error NativeTransferFailed();
    /// @dev EIP-712 signature deadline has passed. SpokePool only.
    error SignatureExpired();

    /// @notice Emitted when the admin withdraws tokens from the clone.
    event AdminWithdraw(address indexed token, address indexed to, uint256 amount);
    /// @notice Emitted when the user withdraws tokens from the clone.
    event UserWithdraw(address indexed token, address indexed to, uint256 amount);

    /**
     * @notice Admin withdraw to an arbitrary recipient.
     * @param params ABI-encoded route parameters (verified against stored hash).
     * @param token ERC20 token to withdraw, or NATIVE_ASSET for native ETH.
     * @param to Recipient of the withdrawn tokens.
     * @param amount Amount to withdraw.
     */
    function adminWithdraw(bytes calldata params, address token, address to, uint256 amount) external;

    /**
     * @notice Admin withdraw that always sends to the clone's userWithdrawAddress.
     * @param params ABI-encoded route parameters (verified against stored hash).
     * @param token ERC20 token to withdraw, or NATIVE_ASSET for native ETH.
     * @param amount Amount to withdraw.
     */
    function adminWithdrawToUser(bytes calldata params, address token, uint256 amount) external;

    /**
     * @notice User withdraw (escape hatch before execution).
     * @param params ABI-encoded route parameters (verified against stored hash).
     * @param token ERC20 token to withdraw, or NATIVE_ASSET for native ETH.
     * @param to Recipient of the withdrawn tokens.
     * @param amount Amount to withdraw.
     */
    function userWithdraw(bytes calldata params, address token, address to, uint256 amount) external;
}
