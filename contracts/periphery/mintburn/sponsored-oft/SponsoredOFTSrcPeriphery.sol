// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.23;

import { Quote } from "./Structs.sol";
import { QuoteSignLib } from "./QuoteSignLib.sol";
import { ComposeMsgCodec } from "./ComposeMsgCodec.sol";

import { IOFT, SendParam, MessagingFee } from "../../../interfaces/IOFT.sol";
import { AddressToBytes32 } from "../../../libraries/AddressConverters.sol";
import { MinimalLZOptions } from "../../../libraries/MinimalLZOptions.sol";

// TODO? make Ownable and allow to change ApiPubKey and DstComposer. For Phase0, can keep it like this and just redeploy
// This contract is to be used on source chain to route OFT sends through it. It's responsible for emitting an Across-
// specific send events, checking the API signature and sending the transfer via OFT
// TODO! Make this pausable
contract SponsoredOFTSrcPeriphery {
    // TODO: instead of using `AddressToBytes32`, maybe just inline the function here? Feels more visible this way (no
    // one can accidentally break this contract by changing that function)
    using AddressToBytes32 for address;
    using MinimalLZOptions for bytes;

    // @dev gas savings.
    bytes public constant EMPTY_MSG_BYTES = new bytes(0);

    // TODO? which of these should be non-immutable?
    address public immutable TOKEN; // token that is sendable over `oftMessenger`
    address public immutable OFT_MESSENGER;
    address public immutable API_PUBKEY; // pubKey that's used for ECDSA signing from the API side
    address public immutable DST_COMPOSER;

    mapping(bytes32 => bool) public quoteNonces;

    // @dev This event is to be used for auxiliary information in concert with OftSent event to get relevant sponsored
    // quote details
    event SponsoredOFTSend(
        bytes32 indexed quoteNonce,
        address indexed originSender,
        bytes32 indexed finalRecipient,
        uint256 quoteDeadline,
        uint256 maxBpsToSponsor,
        bytes32 finalToken,
        bytes sig
    );

    // TODO: make Ownable and allow to change ApiPubKey and DstComposer
    constructor(address token, address oftMessenger, address apiPubKey, address dstComposer) {
        TOKEN = token;
        OFT_MESSENGER = oftMessenger;
        API_PUBKEY = apiPubKey;
        DST_COMPOSER = dstComposer;
    }

    // @dev The API recommended the user set some `msg.value` in order to pay OFT fee for this transfer. If it's not
    // enough to cover `fee.nativeFee`, we revert. If `msg.value > nativeFee`, `refundAddress` receives excess
    function deposit(Quote calldata quote, bytes calldata signature) external payable {
        // Step 1: check that the quote is signed correctly
        require(QuoteSignLib.isSignatureValid(API_PUBKEY, quote.signedParams, signature), "Incorrect signature");

        // Step 2: check that the quote params make sense: e.g. quoteDeadline is not hit, quote nonce is unique
        require(quote.signedParams.deadline <= block.timestamp, "quote expired");
        require(quoteNonces[quote.signedParams.nonce] == false, "quote already used");
        quoteNonces[quote.signedParams.nonce] = true;

        // Step 3: build oft send params from quote
        (SendParam memory sendParam, MessagingFee memory fee, address refundAddress) = _buildOftTransfer(quote);

        // Step 4: send oft transfer
        IOFT(OFT_MESSENGER).send(sendParam, fee, refundAddress);

        // Step 5: emit event with accepted quote details
        emit SponsoredOFTSend(
            quote.signedParams.nonce,
            msg.sender,
            quote.signedParams.finalRecipient,
            quote.signedParams.deadline,
            quote.signedParams.maxBpsToSponsor,
            quote.signedParams.finalToken,
            signature
        );
    }

    function _buildOftTransfer(
        Quote calldata quote
    ) internal view returns (SendParam memory, MessagingFee memory, address) {
        // TODO? consider passing in composer as a part of quote
        bytes32 to = DST_COMPOSER.toBytes32();

        bytes memory composeMsg = ComposeMsgCodec._encode(
            quote.signedParams.nonce,
            quote.signedParams.deadline,
            quote.signedParams.maxBpsToSponsor,
            quote.signedParams.finalRecipient,
            quote.signedParams.finalToken
        );

        // TODO? For better flexibility, this can be set by the caller instead. However, writing a lib for this on the
        // API side is probably trickier.
        // TODO: test and see what real gas limits we need for both of these calls: lzReceive and lzCompose
        bytes memory extraOptions = MinimalLZOptions
            .newOptions()
            .addExecutorLzReceiveOption(uint128(50_000), uint128(0))
            .addExecutorLzComposeOption(uint16(0), uint128(200_000), uint128(0));

        SendParam memory sendParam = SendParam(
            quote.signedParams.dstEid,
            to,
            // @dev We currently don't OFT sends that take fees in sent token, so set `minAmountLD = amountLD`
            quote.signedParams.amountLD,
            quote.signedParams.amountLD,
            extraOptions,
            composeMsg,
            // TODO? might want to sign off on it being 0x instead of setting on the contract for more flexibility
            // @dev Instead of passing `oftCmd` from the API, we're hardcoding to 0x here. In practice, this will
            // probably not be a problem for any token we want to support
            EMPTY_MSG_BYTES
        );

        MessagingFee memory fee = IOFT(OFT_MESSENGER).quoteSend(sendParam, false);

        return (sendParam, fee, quote.unsignedParams.refundRecipient);
    }
}
