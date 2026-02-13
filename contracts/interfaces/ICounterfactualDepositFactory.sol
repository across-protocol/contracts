// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

/**
 * @title ICounterfactualDepositFactory
 * @notice Interface for the counterfactual deposit factory system
 * @dev This factory creates reusable deposit addresses via CREATE2 that deposit via SponsoredCCTP.
 *      Clones store only a hash of the route params; full params are passed at execution time.
 */
interface ICounterfactualDepositFactory {
    /**
     * @notice Route parameters that define a deposit address.
     * @dev A keccak256 hash of the ABI-encoded struct is stored as the clone's sole immutable arg.
     *      Full params are passed by the caller at execution time and verified against the stored hash.
     */
    struct CounterfactualImmutables {
        uint32 destinationDomain;
        bytes32 mintRecipient;
        bytes32 burnToken;
        bytes32 destinationCaller;
        uint256 cctpMaxFeeBps;
        uint256 executionFee;
        uint32 minFinalityThreshold;
        uint256 maxBpsToSponsor;
        uint256 maxUserSlippageBps;
        bytes32 finalRecipient;
        bytes32 finalToken;
        uint32 destinationDex;
        uint8 accountCreationMode;
        uint8 executionMode;
        bytes32 userWithdrawAddress;
        bytes32 adminWithdrawAddress;
        bytes actionData;
    }

    /// @notice Emitted when a new deposit address is created
    event DepositAddressCreated(
        address indexed depositAddress,
        bytes32 burnToken,
        uint32 destinationDomain,
        bytes32 indexed finalRecipient,
        bytes32 salt
    );

    /// @notice Emitted when a deposit is executed via CCTP
    event DepositExecuted(address indexed depositAddress, uint256 amount, bytes32 nonce);

    /// @notice Emitted when admin withdraws tokens from a deposit contract
    event AdminWithdraw(address indexed depositAddress, address indexed token, address indexed to, uint256 amount);

    /// @notice Emitted when user withdraws tokens from a deposit contract
    event UserWithdraw(address indexed depositAddress, address indexed token, address indexed to, uint256 amount);

    /// @notice Caller is not authorized
    error Unauthorized();

    /// @notice Insufficient token balance for deposit
    error InsufficientBalance();

    /// @notice Provided params do not match the stored hash
    error InvalidParamsHash();

    function predictDepositAddress(
        address executor,
        CounterfactualImmutables memory params,
        bytes32 salt
    ) external view returns (address);

    function deploy(address executor, CounterfactualImmutables memory params, bytes32 salt) external returns (address);

    function deployAndExecute(
        address executor,
        CounterfactualImmutables memory params,
        bytes32 salt,
        uint256 amount,
        address executionFeeRecipient,
        bytes32 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external returns (address depositAddress);

    function executeOnExisting(
        address depositAddress,
        CounterfactualImmutables memory params,
        uint256 amount,
        address executionFeeRecipient,
        bytes32 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external;
}
