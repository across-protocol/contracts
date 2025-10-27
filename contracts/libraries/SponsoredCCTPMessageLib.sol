// SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

import { SponsoredCCTPQuoteLib } from "./SponsoredCCTPQuoteLib.sol";
import { SponsoredCCTPInterface } from "../interfaces/SponsoredCCTPInterface.sol";
import { Bytes32ToAddress } from "./AddressConverters.sol";
import { CommonFlowParams } from "../periphery/mintburn/Structs.sol";

/// @title SponsoredCCTPMessageLib
/// @notice Library to process CCTP messages and extract flow parameters
library SponsoredCCTPMessageLib {
    using Bytes32ToAddress for bytes32;

    struct MessageProcessingResult {
        bool shouldProcess;
        bool isQuoteValid;
        CommonFlowParams commonParams;
        uint8 executionMode;
        bytes actionData;
        uint256 maxUserSlippageBps;
    }

    /**
     * @notice Processes a CCTP message and extracts the flow parameters
     * @param message The CCTP message
     * @param signature The quote signature
     * @param signer The authorized signer address
     * @param baseToken The base token address
     * @param quoteDeadlineBuffer The deadline buffer for quote validation
     * @return result The processing result containing all extracted parameters
     */
    function processMessage(
        bytes memory message,
        bytes memory signature,
        address signer,
        address baseToken,
        uint256 quoteDeadlineBuffer
    ) external view returns (MessageProcessingResult memory result) {
        // Validate message format
        if (!SponsoredCCTPQuoteLib.validateMessage(message)) {
            result.shouldProcess = false;
            return result;
        }

        result.shouldProcess = true;

        // Extract quote data
        (SponsoredCCTPInterface.SponsoredCCTPQuote memory quote, uint256 feeExecuted) = SponsoredCCTPQuoteLib
            .getSponsoredCCTPQuoteData(message);

        // Validate quote (nonce check done by caller)
        result.isQuoteValid =
            SponsoredCCTPQuoteLib.validateSignature(signer, quote, signature) &&
            quote.deadline + quoteDeadlineBuffer >= block.timestamp;

        uint256 amountAfterFees = quote.amount - feeExecuted;

        // Build common flow params
        result.commonParams = CommonFlowParams({
            amountInEVM: amountAfterFees,
            quoteNonce: quote.nonce,
            finalRecipient: quote.finalRecipient.toAddress(),
            finalToken: result.isQuoteValid ? quote.finalToken.toAddress() : baseToken,
            maxBpsToSponsor: result.isQuoteValid ? quote.maxBpsToSponsor : 0,
            extraFeesIncurred: feeExecuted
        });

        result.executionMode = quote.executionMode;
        result.actionData = quote.actionData;
        result.maxUserSlippageBps = quote.maxUserSlippageBps;
    }
}
