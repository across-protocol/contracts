// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { SignatureChecker } from "@openzeppelin/contracts-v4/utils/cryptography/SignatureChecker.sol";

import { SponsoredCCTPInterface } from "../interfaces/SponsoredCCTPInterface.sol";
import { BytesLib } from "../external/libraries/BytesLib.sol";
import { Bytes32ToAddress } from "./AddressConverters.sol";

/**
 * @title SponsoredCCTPQuoteLib
 * @notice Library that contains the functions to get the data from the quotes and validate the signatures.
 */
library SponsoredCCTPQuoteLib {
    using BytesLib for bytes;
    using Bytes32ToAddress for bytes32;

    /// @dev Indices of each field in message that we get from CCTP
    /// Source: https://github.com/circlefin/evm-cctp-contracts/blob/4061786a5726bc05f99fcdb53b0985599f0dbaf7/src/messages/v2/MessageV2.sol#L52-L61
    uint256 private constant VERSION_INDEX = 0;
    uint256 private constant SOURCE_DOMAIN_INDEX = 4;
    uint256 private constant DESTINATION_DOMAIN_INDEX = 8;
    uint256 private constant NONCE_INDEX = 12;
    uint256 private constant SENDER_INDEX = 44;
    uint256 private constant RECIPIENT_INDEX = 76;
    uint256 private constant DESTINATION_CALLER_INDEX = 108;
    uint256 private constant MIN_FINALITY_THRESHOLD_INDEX = 140;
    uint256 private constant FINALITY_THRESHOLD_EXECUTED_INDEX = 144;
    uint256 private constant MESSAGE_BODY_INDEX = 148;

    /// @dev Indices of each field in message body that is extracted from message
    /// Source: https://github.com/circlefin/evm-cctp-contracts/blob/4061786a5726bc05f99fcdb53b0985599f0dbaf7/src/messages/v2/BurnMessageV2.sol#L48-L52
    uint256 private constant BURN_TOKEN_INDEX = 4;
    uint256 private constant MINT_RECIPIENT_INDEX = 36;
    uint256 private constant AMOUNT_INDEX = 68;
    uint256 private constant MAX_FEE_INDEX = 132;
    uint256 private constant FEE_EXECUTED_INDEX = 164;
    uint256 private constant HOOK_DATA_INDEX = 228;

    // Minimum length of the message body (can be longer due to variable actionData)
    uint256 private constant MIN_MSG_BYTES_LENGTH = 664;

    /**
     * @notice Gets the data for the deposit for burn.
     * @param quote The quote that contains the data for the deposit.
     * @return amount The amount of tokens to deposit for burn.
     * @return destinationDomain The destination domain ID for the chain that the tokens are being deposited to.
     * @return mintRecipient The recipent of the minted tokens. This would be the destination periphery contract.
     * @return burnToken The address of the token to burn.
     * @return destinationCaller The address that will call the CCTP receiveMessage function. This would be the destination periphery contract.
     * @return maxFee The maximum fee that can be paid for the deposit.
     * @return minFinalityThreshold The minimum finality threshold for the deposit.
     * @return hookData The hook data for the deposit. Contrains additional data to be used by the destination periphery contract.
     */
    function getDepositForBurnData(
        SponsoredCCTPInterface.SponsoredCCTPQuote memory quote
    )
        internal
        pure
        returns (
            uint256 amount,
            uint32 destinationDomain,
            bytes32 mintRecipient,
            address burnToken,
            bytes32 destinationCaller,
            uint256 maxFee,
            uint32 minFinalityThreshold,
            bytes memory hookData
        )
    {
        amount = quote.amount;
        destinationDomain = quote.destinationDomain;
        mintRecipient = quote.mintRecipient;
        burnToken = quote.burnToken.toAddress();
        destinationCaller = quote.destinationCaller;
        maxFee = quote.maxFee;
        minFinalityThreshold = quote.minFinalityThreshold;
        hookData = abi.encode(
            quote.nonce,
            quote.deadline,
            quote.maxBpsToSponsor,
            quote.maxUserSlippageBps,
            quote.finalRecipient,
            quote.finalToken,
            quote.executionMode,
            quote.actionData
        );
    }

    /**
     * @notice Validates the message that is received from CCTP. If this checks fails, then the quote on source chain was invalid
     * and we are unable to retrieve user's address to send the funds to. In that case the funds will stay in this contract.
     * @param message The message that is received from CCTP.
     * @return isValid True if the message is valid, false otherwise.
     */
    function validateMessage(bytes memory message) internal view returns (bool) {
        // Message must be at least the minimum length (can be longer due to variable actionData)
        if (message.length < MIN_MSG_BYTES_LENGTH) {
            return false;
        }

        // Mint recipient should be this contract
        if (message.toBytes32(MESSAGE_BODY_INDEX + MINT_RECIPIENT_INDEX).toAddress() != address(this)) {
            return false;
        }

        // Validate that finalRecipient and finalToken addresses are valid
        bytes memory messageBody = message.slice(MESSAGE_BODY_INDEX, message.length);
        bytes memory hookData = messageBody.slice(HOOK_DATA_INDEX, messageBody.length);

        // Decode to check address validity
        (, , , , bytes32 finalRecipient, bytes32 finalToken, , ) = abi.decode(
            hookData,
            (bytes32, uint256, uint256, uint256, bytes32, bytes32, uint8, bytes)
        );

        return finalRecipient.isValidAddress() && finalToken.isValidAddress();
    }

    /**
     * @notice Returns the quote and the fee that was executed from the CCTP message.
     * @param message The message that is received from CCTP.
     * @return quote The quote that contains the data of the deposit.
     * @return feeExecuted The fee that was executed for the deposit. This is the fee that was paid to the CCTP message transmitter.
     */
    function getSponsoredCCTPQuoteData(
        bytes memory message
    ) internal pure returns (SponsoredCCTPInterface.SponsoredCCTPQuote memory quote, uint256 feeExecuted) {
        quote.sourceDomain = message.toUint32(SOURCE_DOMAIN_INDEX);
        quote.destinationDomain = message.toUint32(DESTINATION_DOMAIN_INDEX);
        quote.destinationCaller = message.toBytes32(DESTINATION_CALLER_INDEX);
        quote.minFinalityThreshold = message.toUint32(MIN_FINALITY_THRESHOLD_INDEX);

        // first need to extract the message body from the message
        bytes memory messageBody = message.slice(MESSAGE_BODY_INDEX, message.length);
        quote.mintRecipient = messageBody.toBytes32(MINT_RECIPIENT_INDEX);
        quote.amount = messageBody.toUint256(AMOUNT_INDEX);
        quote.burnToken = messageBody.toBytes32(BURN_TOKEN_INDEX);
        quote.maxFee = messageBody.toUint256(MAX_FEE_INDEX);
        feeExecuted = messageBody.toUint256(FEE_EXECUTED_INDEX);

        bytes memory hookData = messageBody.slice(HOOK_DATA_INDEX, messageBody.length);
        (
            quote.nonce,
            quote.deadline,
            quote.maxBpsToSponsor,
            quote.maxUserSlippageBps,
            quote.finalRecipient,
            quote.finalToken,
            quote.executionMode,
            quote.actionData
        ) = abi.decode(hookData, (bytes32, uint256, uint256, uint256, bytes32, bytes32, uint8, bytes));
    }

    /**
     * @notice Validates the signature against the quote.
     * @param signer The signer address that was used to sign the quote.
     * @param quote The quote that contains the data of the deposit.
     * @param signature The signature of the quote.
     * @return isValid True if the signature is valid, false otherwise.
     */
    function validateSignature(
        address signer,
        SponsoredCCTPInterface.SponsoredCCTPQuote memory quote,
        bytes memory signature
    ) internal view returns (bool) {
        // Need to split the hash into two parts to avoid stack too deep error
        bytes32 hash1 = keccak256(
            abi.encode(
                quote.sourceDomain,
                quote.destinationDomain,
                quote.mintRecipient,
                quote.amount,
                quote.burnToken,
                quote.destinationCaller,
                quote.maxFee,
                quote.minFinalityThreshold
            )
        );

        bytes32 hash2 = keccak256(
            abi.encode(
                quote.nonce,
                quote.deadline,
                quote.maxBpsToSponsor,
                quote.maxUserSlippageBps,
                quote.finalRecipient,
                quote.finalToken,
                quote.executionMode,
                keccak256(quote.actionData) // Hash the actionData to keep signature size reasonable
            )
        );

        bytes32 typedDataHash = keccak256(abi.encode(hash1, hash2));
        return SignatureChecker.isValidSignatureNow(signer, typedDataHash, signature);
    }
}
