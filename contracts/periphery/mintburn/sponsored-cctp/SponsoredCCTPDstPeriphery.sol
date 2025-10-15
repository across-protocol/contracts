//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IMessageTransmitterV2 } from "../../../external/interfaces/CCTPInterfaces.sol";

import { SponsoredCCTPQuoteLib } from "../../../libraries/SponsoredCCTPQuoteLib.sol";
import { SponsoredCCTPInterface } from "../../../interfaces/SponsoredCCTPInterface.sol";
import { Bytes32ToAddress } from "../../../libraries/AddressConverters.sol";

contract SponsoredCCTPDstPeriphery is SponsoredCCTPInterface, Ownable {
    using Bytes32ToAddress for bytes32;

    IMessageTransmitterV2 public immutable cctpMessageTransmitter;

    address public signer;

    mapping(bytes32 => bool) public usedNonces;

    constructor(address _cctpMessageTransmitter, address _signer) {
        cctpMessageTransmitter = IMessageTransmitterV2(_cctpMessageTransmitter);
        signer = _signer;
    }

    function receiveMessage(bytes memory message, bytes memory attestation, bytes memory signature) external {
        cctpMessageTransmitter.receiveMessage(message, attestation);

        (SponsoredCCTPInterface.SponsoredCCTPQuote memory quote, uint256 feeExecuted) = SponsoredCCTPQuoteLib
            .getSponsoredCCTPQuoteData(message);

        if (
            !SponsoredCCTPQuoteLib.validateSignature(signer, quote, signature) ||
            usedNonces[quote.nonce] ||
            quote.deadline < block.timestamp ||
            quote.maxBpsToSponsor == 0
        ) {
            // send the received funds to the final recipient on CORE
            IERC20(quote.finalToken.toAddress()).transfer(quote.finalRecipient.toAddress(), quote.amount);
            emit SponsoredMintAndWithdraw(
                quote.nonce,
                quote.finalRecipient,
                quote.finalToken,
                quote.amount,
                quote.deadline,
                quote.maxBpsToSponsor
            );
        } else {
            // send the received + fee to the final recipient on CORE
            IERC20(quote.finalToken.toAddress()).transfer(quote.finalRecipient.toAddress(), quote.amount + feeExecuted);
            emit SponsoredMintAndWithdraw(
                quote.nonce,
                quote.finalRecipient,
                quote.finalToken,
                quote.amount + feeExecuted,
                quote.deadline,
                quote.maxBpsToSponsor
            );
        }
    }

    function setSigner(address _signer) external onlyOwner {
        signer = _signer;
    }

    // Only used for testing
    function sweepErc20(address token, address to, uint256 amount) external onlyOwner {
        IERC20(token).transfer(to, amount);
    }
}
