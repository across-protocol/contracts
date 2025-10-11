// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.23;

import { SendParam, MessagingFee } from "../../interfaces/IOFT.sol";

struct SponsoredOFTQuote {
    SponsoredOFTQuoteSignedParams signedParams;
    SponsoredOFTQuoteUnsignedParams unsignedParams;
}

struct SponsoredOFTQuoteSignedParams {
    uint32 srcEid; // Source endpoint ID.
    // TODO: this may be overkill?
    address srcPeriphery; // Source periphery contract that's allowed to be used
    // From default OFT .send() params
    uint32 dstEid; // Destination endpoint ID.
    bytes32 to; // Recipient address. Address of our Composer contract
    uint256 amountLD; // Amount to send in local decimals.
    // ! TODO might want to sign off on it being 0x instead of checking on the contract address just for more flexibility
    // bytes oftCmd; // The OFT command to be executed, unused in default OFT implementations.
    // From `composeMsg`
    bytes32 nonce; // quote nonce
    uint256 deadline; // quote deadline
    uint256 maxSponsorshipAmount; // max amount to sponsor for 1:1. in dst chain decimals (chain that Composer lives on)
    bytes32 finalRecipient; // user address on destination
    bytes32 finalToken; // final token we want to receive (might be different from OFT token we're sending)
}

// The rest of params that go into OFT.send() that we don't sign from the API side
struct SponsoredOFTQuoteUnsignedParams {
    uint256 minAmountLD;
    bytes extraOptions; // Gas options for lzReceive and lzCompose executions
    // TODO: check that below is OK. Is USDT0 using 0x?
    bytes oftCmd; // We're not signing off on this but instead we're checking that it's 0x
    // TODO: actually, we may not want to pre-calc this in the API. We might give user a `msg.value` estimation and
    // TODO: then we'll recalc in the contract atomically and use `refundRecipient` to refund if too big. Just so that
    // TODO: we don't revert because of `messagingFee` being incorrect to the wei
    MessagingFee messagingFee; // fees that we're including with our OFT call.
    address refundRecipient; // recipient of extra msg.value passed into the OFT send on src chain
}
