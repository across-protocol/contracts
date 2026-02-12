// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

/**
 * @title ICounterfactualDepositFactory
 * @notice Interface for the counterfactual deposit factory system
 * @dev This factory creates reusable deposit addresses via CREATE2 that deposit via SponsoredCCTP
 */
interface ICounterfactualDepositFactory {
    /**
     * @notice Route parameters stored as immutable args in each clone's bytecode
     * @dev These define the deposit route and are fixed at address-generation time.
     *      Execution-time parameters (amount, nonce, deadline) are passed separately.
     */
    struct CCTPRouteParams {
        uint32 destinationDomain;
        bytes32 mintRecipient;
        bytes32 burnToken;
        bytes32 destinationCaller;
        uint256 maxFeeBps;
        uint32 minFinalityThreshold;
        uint256 maxBpsToSponsor;
        uint256 maxUserSlippageBps;
        bytes32 finalRecipient;
        bytes32 finalToken;
        uint32 destinationDex;
        uint8 accountCreationMode;
        uint8 executionMode;
        bytes32 refundAddress;
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

    /// @notice Emitted when admin is updated
    event AdminUpdated(address indexed oldAdmin, address indexed newAdmin);

    /// @notice Caller is not authorized
    error Unauthorized();

    /// @notice Insufficient token balance for deposit
    error InsufficientBalance();

    function predictDepositAddress(
        address executor,
        CCTPRouteParams memory params,
        bytes32 salt
    ) external view returns (address);

    function deploy(address executor, CCTPRouteParams memory params, bytes32 salt) external returns (address);

    function deployAndExecute(
        address executor,
        CCTPRouteParams memory params,
        bytes32 salt,
        uint256 amount,
        bytes32 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external returns (address depositAddress);

    function executeOnExisting(
        address depositAddress,
        uint256 amount,
        bytes32 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external;

    function setAdmin(address newAdmin) external;

    function admin() external view returns (address);
}
