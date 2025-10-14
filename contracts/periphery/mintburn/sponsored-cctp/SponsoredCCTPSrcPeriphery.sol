//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ITokenMessengerV2 } from "../../../external/interfaces/CCTPInterfaces.sol";

import { SponsoredCCTPQuoteLib } from "../../../libraries/SponsoredCCTPQuoteLib.sol";
import { SponsoredCCTPInterface } from "../../../interfaces/SponsoredCCTPInterface.sol";

contract SponsoredCCTPPeriphery is SponsoredCCTPInterface {
    ITokenMessengerV2 public immutable cctpTokenMessenger;

    address public signer;

    mapping(bytes32 => bool) public usedNonces;

    constructor(ITokenMessengerV2 _cctpTokenMessenger, address _signer) {
        cctpTokenMessenger = _cctpTokenMessenger;
        signer = _signer;
    }

    using SponsoredCCTPQuoteLib for bytes;

    function depositForBurn(SponsoredCCTPInterface.SponsoredCCTPQuote memory quote, bytes memory signature) external {
        if (!SponsoredCCTPQuoteLib.validateSignature(signer, quote, signature)) revert InvalidSignature();
        if (usedNonces[quote.nonce]) revert InvalidNonce();
        if (quote.deadline < block.timestamp) revert InvalidDeadline();

        IERC20(quote.burnToken).transferFrom(msg.sender, address(this), quote.amount);
        IERC20(quote.burnToken).approve(address(cctpTokenMessenger), quote.amount);

        usedNonces[quote.nonce] = true;
        bytes memory hookData = abi.encode(
            quote.nonce,
            quote.deadline,
            quote.maxSponsoredAmount,
            quote.finalRecipient,
            quote.finalToken,
            signature
        );

        cctpTokenMessenger.depositForBurnWithHook(
            quote.amount,
            quote.destinationDomain,
            quote.mintRecipient,
            quote.burnToken,
            quote.destinationCaller,
            quote.maxFee,
            quote.minFinalityThreshold,
            hookData
        );

        emit CCTPQuoteDeposited(
            msg.sender,
            quote.burnToken,
            quote.amount,
            quote.destinationDomain,
            quote.mintRecipient,
            quote.finalRecipient,
            quote.finalToken,
            quote.destinationCaller,
            quote.nonce
        );
    }
}
