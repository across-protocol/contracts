// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.23;

import { SponsoredOFTQuote } from "./SponsoredOftMintBurnStructs.sol";
import { SponsoredOFTQuoteSignLib } from "./SponsoredOFTQuoteSignLib.sol";
import { SponsoredOFTComposeCodec } from "./SponsoredOFTComposeCodec.sol";
import { IOFT, SendParam, MessagingFee } from "../../interfaces/IOFT.sol";
import { AddressToBytes32 } from "../../libraries/AddressConverters.sol";
import { OptionsBuilder } from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";

// This contract is to be used on source chain to route OFT sends through it. It's responsible for emitting an Across-
// specific send events, checking the API signature and sending the transfer via OFT
contract SrcPeripheryOFT {
    using AddressToBytes32 for address;

    // @notice Empty bytes array used for OFT messaging parameters
    bytes public constant EMPTY_MSG_BYTES = new bytes(0);

    // TODO? which of these should be non-immutable?
    address public immutable TOKEN; // token that is sendable over `oftMessenger`
    address public immutable OFT_MESSENGER;
    address public immutable API_PUBKEY; // pubKey that's used for ECDSA signing from the API side
    address public immutable DST_COMPOSER;

    mapping(bytes32 => bool) public quoteNonces;

    function deposit(SponsoredOFTQuote calldata quote, bytes calldata signature) external {
        // TODO? tryVerify
        // Step 1: check that the quote is signed correctly
        SponsoredOFTQuoteSignLib.verify(API_PUBKEY, quote.signedParams, signature);

        // Step 2: check that the quote params make sense: e.g. quoteDeadline is not hit, quote nonce is unique
        require(quote.signedParams.deadline <= block.timestamp, "quote expired");
        require(quoteNonces[quote.signedParams.nonce] == false, "quote already used");
        quoteNonces[quote.signedParams.nonce] = true;

        // Step 3: send oft transfer
        // TODO: here, we're calculating fee on chain. What do the params from API mean then?
        // TODO: maybe they can mean: maxNativeFeeUserIsWillingToPay (recommended by API, or manually configured by user)
        // TODO: Then if the lzFee.nativeFee is too much, we revert here instead of on DST. There are still possibilities
        // TODO: to revert on destination because of gas options
        (SendParam memory sendParam, MessagingFee memory fee, address refundAddress) = _buildOftTransfer(quote);
        IOFT(OFT_MESSENGER).send(sendParam, fee, refundAddress);
    }

    // Helper function that converts the quote user should have received from the API and builds params to call
    // OFT_MESSENGER.send with
    function _buildOftTransfer(
        SponsoredOFTQuote calldata quote
    ) internal view returns (SendParam memory, MessagingFee memory, address) {
        // TODO? consider passing in composer as a part of quote
        bytes32 to = DST_COMPOSER.toBytes32();

        bytes memory composeMsg = SponsoredOFTComposeCodec._encode(
            quote.signedParams.nonce,
            quote.signedParams.deadline,
            quote.signedParams.maxSponsorshipAmount,
            quote.signedParams.finalRecipient,
            quote.signedParams.finalToken
        );

        // Build LayerZero executor options for receive + compose
        bytes memory extraOptions = OptionsBuilder.newOptions();
        extraOptions = OptionsBuilder.addExecutorLzReceiveOption(extraOptions, uint128(50_000), uint128(0));
        extraOptions = OptionsBuilder.addExecutorLzComposeOption(extraOptions, uint16(0), uint128(30_000), uint128(0));

        // @dev we're enforcing empty oftCmd on source periphery, which in turn enforces in on dst, because dst will
        // check that the sender is this periphery contract
        // TODO: if we sign over oftCmd instead, then we can be more flexible in supporting different oftCmds if they're
        // not harmful towards our transfer flow. But in reality we probably don't care about supporting those
        // TODO: this check is sus
        require(quote.unsignedParams.oftCmd.length == 0, "Custom oft cmd not supported");

        SendParam memory sendParam = SendParam(
            quote.signedParams.dstEid,
            to,
            /**
             * _amount, _amount here specify `amountLD` and `minAmountLD`. Setting `minAmountLD` equal to `amountLD` protects us
             * from any changes to the sent amount due to internal OFT contract logic, e.g. `_removeDust`. Meaning that if any
             * dust is subtracted, the `.send()` should revert
             */
            quote.signedParams.amountLD,
            quote.signedParams.amountLD,
            /** extraOptions, composeMsg, oftCmd */
            extraOptions,
            composeMsg,
            EMPTY_MSG_BYTES
        );

        // `false` in the 2nd param here refers to `bool _payInLzToken`. We will pay in native token, so set to `false`
        MessagingFee memory fee = IOFT(OFT_MESSENGER).quoteSend(sendParam, false);

        return (sendParam, fee, quote.unsignedParams.refundRecipient);
    }
}
