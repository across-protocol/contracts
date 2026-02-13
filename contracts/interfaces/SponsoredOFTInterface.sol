// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.23;

import { SponsoredExecutionModeInterface } from "./SponsoredExecutionModeInterface.sol";

/**
 * @title SponsoredOFTInterface
 * @notice Interface for Sponsored OFT quote types and source periphery API.
 * @custom:security-contact bugs@across.to
 */
interface SponsoredOFTInterface is SponsoredExecutionModeInterface {
    /// @notice A structure with all the relevant information about a particular sponsored bridging flow order.
    struct Quote {
        SignedQuoteParams signedParams;
        UnsignedQuoteParams unsignedParams;
    }

    /// @notice Signed params of the sponsored bridging flow quote.
    struct SignedQuoteParams {
        uint32 srcEid; // Source endpoint ID in OFT system.
        // Params passed into OFT.send()
        uint32 dstEid; // Destination endpoint ID in OFT system.
        bytes32 destinationHandler; // `to`. Recipient address. Address of our Composer contract
        uint256 amountLD; // Amount to send in local decimals.
        // Signed params that go into `composeMsg`
        bytes32 nonce; // quote nonce
        uint256 deadline; // Quote deadline. Enforced on source chain only at deposit time, not sent to destination
        uint256 maxBpsToSponsor; // max bps (of sent amount) to sponsor for 1:1
        uint256 maxUserSlippageBps; // slippage tolerance for the swap on the destination
        bytes32 finalRecipient; // user address on destination
        bytes32 finalToken; // final token user will receive (might be different from OFT token we're sending)
        uint32 destinationDex; // destination DEX on HyperCore
        // Signed gas limits for destination-side LZ execution
        uint256 lzReceiveGasLimit; // gas limit for `lzReceive` call on destination side
        uint256 lzComposeGasLimit; // gas limit for `lzCompose` call on destination side
        // Execution mode and action data
        uint256 maxOftFeeBps; // max fee deducted by the OFT bridge
        uint8 accountCreationMode; // AccountCreationMode: Standard or FromUserFunds
        uint8 executionMode; // ExecutionMode: DirectToCore, ArbitraryActionsToCore, or ArbitraryActionsToEVM
        bytes actionData; // Encoded action data for arbitrary execution. Empty for DirectToCore mode.
    }

    /// @notice Unsigned params of the sponsored bridging flow quote: user is free to choose these.
    struct UnsignedQuoteParams {
        address refundRecipient; // recipient of extra msg.value passed into the OFT send on src chain
    }

    /**
     * @notice Event with auxiliary information. To be used in concert with OftSent event to get relevant quote details.
     */
    event SponsoredOFTSend(
        bytes32 indexed quoteNonce,
        address indexed originSender,
        bytes32 indexed finalRecipient,
        bytes32 destinationHandler,
        uint256 quoteDeadline,
        uint256 maxBpsToSponsor,
        uint256 maxUserSlippageBps,
        bytes32 finalToken,
        bytes sig
    );

    /// @notice Thrown when the source eid of the ioft messenger does not match the src eid supplied.
    error IncorrectSrcEid();
    /// @notice Thrown when the supplied token does not match the supplied ioft messenger.
    error TokenIOFTMismatch();
    /// @notice Thrown when the signer for quote does not match `signer`.
    error IncorrectSignature();
    /// @notice Thrown if Quote has expired.
    error QuoteExpired();
    /// @notice Thrown if Quote nonce was already used.
    error NonceAlreadyUsed();
    /// @notice Thrown when provided msg.value is not sufficient to cover OFT bridging fee.
    error InsufficientNativeFee();
    /// @notice Thrown when array lengths do not match.
    error ArrayLengthMismatch();
    /// @notice Thrown when maxOftFeeBps is greater than 10000.
    error InvalidMaxOftFeeBps();

    /**
     * @notice Returns the signer address that is used to validate the signatures of the quotes.
     * @return The signer address.
     */
    function signer() external view returns (address);

    /**
     * @notice Returns true if the nonce has been used, false otherwise.
     * @param nonce The nonce to check.
     * @return True if the nonce has been used, false otherwise.
     */
    function usedNonces(bytes32 nonce) external view returns (bool);

    /**
     * @notice Main entrypoint function to start the user flow.
     * @param quote The quote struct containing all transfer parameters.
     * @param signature The signature authorizing the quote.
     */
    function deposit(Quote calldata quote, bytes calldata signature) external payable;

    /**
     * @notice Sets the quote signer.
     * @param _newSigner New signer address.
     */
    function setSigner(address _newSigner) external;
}
