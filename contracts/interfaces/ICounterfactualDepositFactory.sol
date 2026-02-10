// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

/**
 * @title ICounterfactualDepositFactory
 * @notice Interface for the counterfactual deposit factory system
 * @dev This factory creates reusable deposit addresses via CREATE2
 */
interface ICounterfactualDepositFactory {
    /**
     * @notice Quote parameters for a deposit execution
     * @param depositAddress The specific deposit contract this quote is valid for (binds quote to address)
     * @param deadline Timestamp after which this quote is invalid
     * @param inputAmount Amount of input tokens to deposit
     * @param outputAmount Amount of output tokens to receive on destination
     * @param quoteTimestamp Timestamp for HubPool fee calculation
     * @param fillDeadline Latest timestamp at which the deposit can be filled
     * @param exclusivityParameter Parameter for exclusivity deadline calculation
     * @param exclusiveRelayer Address of exclusive relayer (if any)
     * @dev message is part of the route (immutable in proxy), not part of the quote
     */
    struct DepositQuote {
        address depositAddress;
        uint256 deadline;
        uint256 inputAmount;
        uint256 outputAmount;
        uint32 quoteTimestamp;
        uint32 fillDeadline;
        uint32 exclusivityParameter;
        bytes32 exclusiveRelayer;
    }

    /// @notice Emitted when a new deposit address is created
    event DepositAddressCreated(
        address indexed depositAddress,
        bytes32 inputToken,
        bytes32 outputToken,
        uint256 destinationChainId,
        bytes32 indexed recipient,
        bytes32 salt
    );

    /// @notice Emitted when a deposit is executed
    event DepositExecuted(address indexed depositAddress, uint256 inputAmount, uint256 outputAmount, uint256 depositId);

    /// @notice Emitted when quote signer is updated
    event QuoteSignerUpdated(address indexed oldSigner, address indexed newSigner);

    /// @notice Emitted when admin is updated
    event AdminUpdated(address indexed oldAdmin, address indexed newAdmin);

    /// @notice Invalid signature provided
    error InvalidSignature();

    /// @notice Quote has expired
    error QuoteExpired();

    /// @notice Quote depositAddress doesn't match target
    error WrongDepositAddress();

    /// @notice Caller is not authorized
    error Unauthorized();

    /// @notice Insufficient token balance for deposit
    error InsufficientBalance();

    /// @notice Absolute fee exceeds maximum allowed
    error GasFeeTooHigh();

    /// @notice Percentage fee exceeds maximum allowed
    error CapitalFeeTooHigh();

    /**
     * @notice Predicts the address of a counterfactual deposit contract
     * @param inputToken Input token address (bytes32 for cross-chain compatibility)
     * @param outputToken Output token address
     * @param destinationChainId Destination chain ID
     * @param recipient Recipient address on destination chain
     * @param message Message to forward to recipient
     * @param maxGasFee Maximum absolute fee in wei
     * @param maxCapitalFee Maximum fee as percentage in basis points
     * @param salt Unique salt for address generation
     * @return Predicted address
     */
    function predictDepositAddress(
        bytes32 inputToken,
        bytes32 outputToken,
        uint256 destinationChainId,
        bytes32 recipient,
        bytes memory message,
        uint256 maxGasFee,
        uint256 maxCapitalFee,
        bytes32 salt
    ) external view returns (address);

    /**
     * @notice Deploys a counterfactual deposit contract
     * @param inputToken Input token address
     * @param outputToken Output token address
     * @param destinationChainId Destination chain ID
     * @param recipient Recipient address on destination chain
     * @param message Message to forward to recipient
     * @param maxGasFee Maximum absolute fee in wei
     * @param maxCapitalFee Maximum fee as percentage in basis points
     * @param salt Unique salt for address generation
     * @return Address of deployed contract
     */
    function deploy(
        bytes32 inputToken,
        bytes32 outputToken,
        uint256 destinationChainId,
        bytes32 recipient,
        bytes memory message,
        uint256 maxGasFee,
        uint256 maxCapitalFee,
        bytes32 salt
    ) external returns (address);

    /**
     * @notice Deploys and executes a deposit in one transaction
     * @param inputToken Input token address
     * @param outputToken Output token address
     * @param destinationChainId Destination chain ID
     * @param recipient Recipient address on destination chain
     * @param message Message to forward to recipient
     * @param maxGasFee Maximum absolute fee in wei
     * @param maxCapitalFee Maximum fee as percentage in basis points
     * @param salt Unique salt for address generation
     * @param quote Signed deposit quote
     * @param signature Signature from authorized quoteSigner
     * @return depositAddress Address of deposit contract
     */
    function deployAndExecute(
        bytes32 inputToken,
        bytes32 outputToken,
        uint256 destinationChainId,
        bytes32 recipient,
        bytes memory message,
        uint256 maxGasFee,
        uint256 maxCapitalFee,
        bytes32 salt,
        DepositQuote calldata quote,
        bytes calldata signature
    ) external returns (address depositAddress);

    /**
     * @notice Executes a deposit on an existing contract
     * @param depositAddress Address of existing deposit contract
     * @param quote Signed deposit quote
     * @param signature Signature from authorized quoteSigner
     */
    function executeOnExisting(address depositAddress, DepositQuote calldata quote, bytes calldata signature) external;

    /**
     * @notice Verifies a deposit quote signature
     * @param quote Deposit quote to verify
     * @param signature Signature to verify
     * @return True if signature is valid
     */
    function verifyQuote(DepositQuote calldata quote, bytes calldata signature) external view returns (bool);

    /**
     * @notice Updates the quote signer address
     * @param newSigner New quote signer address
     */
    function setQuoteSigner(address newSigner) external;

    /**
     * @notice Updates the admin address
     * @param newAdmin New admin address
     */
    function setAdmin(address newAdmin) external;

    /**
     * @notice Returns the current admin address
     */
    function admin() external view returns (address);

    /**
     * @notice Returns the current quote signer address
     */
    function quoteSigner() external view returns (address);

    /**
     * @notice Returns the SpokePool address
     */
    function spokePool() external view returns (address);

    /**
     * @notice Returns the executor implementation address
     */
    function executor() external view returns (address);
}
