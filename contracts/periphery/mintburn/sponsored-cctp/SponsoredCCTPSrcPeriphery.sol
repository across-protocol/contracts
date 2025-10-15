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

        (
            uint256 amount,
            uint32 destinationDomain,
            bytes32 mintRecipient,
            address burnToken,
            bytes32 destinationCaller,
            uint256 maxFee,
            uint32 minFinalityThreshold,
            bytes memory hookData
        ) = SponsoredCCTPQuoteLib.getDespoitForBurnData(quote);

        IERC20(burnToken).transferFrom(msg.sender, address(this), amount);
        IERC20(burnToken).approve(address(cctpTokenMessenger), amount);

        usedNonces[quote.nonce] = true;

        cctpTokenMessenger.depositForBurnWithHook(
            amount,
            destinationDomain,
            mintRecipient,
            burnToken,
            destinationCaller,
            maxFee,
            minFinalityThreshold,
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
