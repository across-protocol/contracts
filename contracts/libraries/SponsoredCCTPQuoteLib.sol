// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { SignatureChecker } from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";

import { SponsoredCCTPInterface } from "../interfaces/SponsoredCCTPInterface.sol";
import { BytesLib } from "./BytesLib.sol";
import { Bytes32ToAddress } from "./AddressConverters.sol";

library SponsoredCCTPQuoteLib {
    using BytesLib for bytes;
    using Bytes32ToAddress for bytes32;

    // Indices of each field in message
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

    // Field indices in message body
    uint256 private constant BURN_TOKEN_INDEX = 4;
    uint256 private constant MINT_RECIPIENT_INDEX = 36;
    uint256 private constant AMOUNT_INDEX = 68;
    uint256 private constant MAX_FEE_INDEX = 132;
    uint256 private constant FEE_EXECUTED_INDEX = 164;
    uint256 private constant HOOK_DATA_INDEX = 228;

    // Minimum length of the message body (can be longer due to variable actionData)
    uint256 private constant MIN_MSG_BYTES_LENGTH = 568;

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

    function getSponsoredCCTPQuoteData(
        bytes memory message
    ) internal pure returns (SponsoredCCTPInterface.SponsoredCCTPQuote memory quote, uint256 feeExecuted) {
        quote.sourceDomain = message.toUint32(SOURCE_DOMAIN_INDEX);
        quote.destinationDomain = message.toUint32(DESTINATION_DOMAIN_INDEX);
        quote.destinationCaller = message.toBytes32(DESTINATION_CALLER_INDEX);
        quote.minFinalityThreshold = message.toUint32(MIN_FINALITY_THRESHOLD_INDEX);

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
