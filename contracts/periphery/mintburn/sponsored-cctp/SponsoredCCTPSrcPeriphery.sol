//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ITokenMessengerV2 } from "../../../external/interfaces/CCTPInterfaces.sol";

import { SponsoredCCTPQuoteLib } from "../../../libraries/SponsoredCCTPQuoteLib.sol";
import { SponsoredCCTPInterface } from "../../../interfaces/SponsoredCCTPInterface.sol";

contract SponsoredCCTPSrcPeriphery is SponsoredCCTPInterface, Ownable {
    ITokenMessengerV2 public immutable cctpTokenMessenger;

    address public signer;

    mapping(bytes32 => bool) public usedNonces;

    constructor(address _cctpTokenMessenger, address _signer) {
        cctpTokenMessenger = ITokenMessengerV2(_cctpTokenMessenger);
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
            quote.maxBpsToSponsor,
            quote.finalRecipient,
            quote.finalToken
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

        emit SponsoredDepositForBurn(
            quote.nonce,
            msg.sender,
            quote.finalRecipient,
            quote.deadline,
            quote.maxBpsToSponsor,
            quote.finalToken,
            signature
        );
    }

    function setSigner(address _signer) external onlyOwner {
        signer = _signer;
    }
}
