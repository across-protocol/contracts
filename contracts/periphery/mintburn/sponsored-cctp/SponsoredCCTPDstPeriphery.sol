//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IMessageTransmitterV2 } from "../../../external/interfaces/CCTPInterfaces.sol";

import { SponsoredCCTPQuoteLib } from "../../../libraries/SponsoredCCTPQuoteLib.sol";
import { SponsoredCCTPInterface } from "../../../interfaces/SponsoredCCTPInterface.sol";

contract SponsoredCCTPPeriphery is SponsoredCCTPInterface {
    IMessageTransmitterV2 public immutable cctpMessageTransmitter;

    address public signer;

    mapping(bytes32 => bool) public usedNonces;

    constructor(IMessageTransmitterV2 _cctpMessageTransmitter, address _signer) {
        cctpMessageTransmitter = _cctpMessageTransmitter;
        signer = _signer;
    }

    function receiveMessage(bytes memory message, bytes memory attestation) external {
        cctpMessageTransmitter.receiveMessage(message, attestation);

        (
            SponsoredCCTPInterface.SponsoredCCTPQuote memory quote,
            uint256 feeExecuted,
            bytes memory signature
        ) = SponsoredCCTPQuoteLib.getSponsoredCCTPQuoteData(message);

        if (
            !SponsoredCCTPQuoteLib.validateSignature(signer, quote, signature) ||
            usedNonces[quote.nonce] ||
            quote.deadline < block.timestamp
        ) {
            // send the received funds to the final recipient on CORE
        } else {
            // send the received + fee to the final recipient on CORE
        }
    }
}
