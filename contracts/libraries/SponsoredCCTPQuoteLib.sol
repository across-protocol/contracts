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
    uint8 private constant VERSION_INDEX = 0;
    uint8 private constant SOURCE_DOMAIN_INDEX = 4;
    uint8 private constant DESTINATION_DOMAIN_INDEX = 8;
    uint8 private constant NONCE_INDEX = 12;
    uint8 private constant SENDER_INDEX = 44;
    uint8 private constant RECIPIENT_INDEX = 76;
    uint8 private constant DESTINATION_CALLER_INDEX = 108;
    uint8 private constant MIN_FINALITY_THRESHOLD_INDEX = 140;
    uint8 private constant FINALITY_THRESHOLD_EXECUTED_INDEX = 144;
    uint8 private constant MESSAGE_BODY_INDEX = 148;

    // Field indices in message body
    uint8 private constant BURN_TOKEN_INDEX = 4;
    uint8 private constant MINT_RECIPIENT_INDEX = 36;
    uint8 private constant AMOUNT_INDEX = 68;
    uint8 private constant MAX_FEE_INDEX = 132;
    uint8 private constant FEE_EXECUTED_INDEX = 164;
    uint8 private constant HOOK_DATA_INDEX = 228;

    function getDespoitForBurnData(
        SponsoredCCTPInterface.SponsoredCCTPQuote memory quote,
        bytes memory signature
    )
        external
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
        burnToken = quote.burnToken;
        destinationCaller = quote.destinationCaller;
        maxFee = quote.maxFee;
        minFinalityThreshold = quote.minFinalityThreshold;
        hookData = abi.encode(
            quote.nonce,
            quote.deadline,
            quote.maxSponsoredAmount,
            quote.finalRecipient,
            quote.finalToken,
            signature
        );
    }

    function getSponsoredCCTPQuoteData(
        bytes calldata message
    )
        external
        pure
        returns (SponsoredCCTPInterface.SponsoredCCTPQuote memory quote, uint256 feeExecuted, bytes memory signature)
    {
        quote.sourceDomain = message.toUint32(SOURCE_DOMAIN_INDEX);
        quote.destinationDomain = message.toUint32(DESTINATION_DOMAIN_INDEX);
        bytes memory messageBody = message.slice(MESSAGE_BODY_INDEX, message.length);
        quote.mintRecipient = messageBody.toBytes32(MINT_RECIPIENT_INDEX);
        quote.amount = messageBody.toUint256(AMOUNT_INDEX);
        quote.burnToken = messageBody.toBytes32(BURN_TOKEN_INDEX).toAddress();
        quote.destinationCaller = messageBody.toBytes32(DESTINATION_CALLER_INDEX);
        quote.minFinalityThreshold = messageBody.toUint32(MIN_FINALITY_THRESHOLD_INDEX);
        quote.maxFee = messageBody.toUint256(MAX_FEE_INDEX);
        feeExecuted = messageBody.toUint256(FEE_EXECUTED_INDEX);

        bytes memory hookData = messageBody.slice(HOOK_DATA_INDEX, messageBody.length);
        (quote.nonce, quote.deadline, quote.maxSponsoredAmount, quote.finalRecipient, quote.finalToken, signature) = abi
            .decode(hookData, (bytes32, uint256, uint256, bytes32, bytes32, bytes));
    }

    function validateSignature(
        address signer,
        SponsoredCCTPInterface.SponsoredCCTPQuote memory quote,
        bytes memory signature
    ) external view returns (bool) {
        bytes32 typedDataHash = keccak256(abi.encode(quote));
        return SignatureChecker.isValidSignatureNow(signer, typedDataHash, signature);
    }
}
