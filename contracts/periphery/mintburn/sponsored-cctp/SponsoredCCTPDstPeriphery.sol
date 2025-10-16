//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IMessageTransmitterV2 } from "../../../external/interfaces/CCTPInterfaces.sol";
import { SponsoredCCTPQuoteLib } from "../../../libraries/SponsoredCCTPQuoteLib.sol";
import { SponsoredCCTPInterface } from "../../../interfaces/SponsoredCCTPInterface.sol";
import { Bytes32ToAddress } from "../../../libraries/AddressConverters.sol";
import { HyperCoreLib } from "../../../libraries/HyperCoreLib.sol";
import { SwapHandler } from "../SwapHandler.sol";
import { CoreTokenInfo } from "../Structs.sol";

contract SponsoredCCTPDstPeriphery is SponsoredCCTPInterface, Ownable {
    using SafeERC20 for IERC20Metadata;
    using Bytes32ToAddress for bytes32;

    IMessageTransmitterV2 public immutable cctpMessageTransmitter;

    address public signer;

    mapping(bytes32 => bool) public usedNonces;

    mapping(address => CoreTokenInfo) public tokenCoreInfo;

    constructor(address _cctpMessageTransmitter, address _signer) {
        cctpMessageTransmitter = IMessageTransmitterV2(_cctpMessageTransmitter);
        signer = _signer;
    }

    function setSigner(address _signer) external onlyOwner {
        signer = _signer;
    }

    function setCoreTokenInfo(address token, CoreTokenInfo memory coreTokenInfo) external onlyOwner {
        tokenCoreInfo[token] = coreTokenInfo;
        if (tokenCoreInfo[token].swapHandler == address(0)) {
            tokenCoreInfo[token].swapHandler = address(new SwapHandler());
        }
    }

    function receiveMessage(bytes memory message, bytes memory attestation, bytes memory signature) external {
        cctpMessageTransmitter.receiveMessage(message, attestation);

        // If the hook data is invalid we cannot process the message and therefore we return
        // in this case the funds will be kept in this contract
        if (!SponsoredCCTPQuoteLib.validateMessage(message)) {
            return;
        }

        (SponsoredCCTPInterface.SponsoredCCTPQuote memory quote, uint256 feeExecuted) = SponsoredCCTPQuoteLib
            .getSponsoredCCTPQuoteData(message);

        if (_isQuoteEligibleForSwap(quote, signature)) {
            uint256 finalAmount = quote.amount;
            address finalRecipient = quote.finalRecipient.toAddress();
            address finalToken = quote.finalToken.toAddress();

            if (!_isQuoteValid(quote, signature)) {
                // send the received funds to the final recipient on CORE
                finalAmount = quote.amount;
            } else {
                // send the received + fee to the final recipient on CORE
                finalAmount = quote.amount + feeExecuted + _getAccountActivationFee(finalToken, finalRecipient);
            }

            HyperCoreLib.transferERC20EVMToCore(
                finalToken,
                tokenCoreInfo[finalToken].coreIndex,
                finalRecipient,
                finalAmount,
                tokenCoreInfo[finalToken].decimalDiff
            );

            emit SponsoredMintAndWithdraw(
                quote.nonce,
                quote.finalRecipient,
                quote.finalToken,
                finalAmount,
                quote.deadline,
                quote.maxBpsToSponsor
            );
        } else {
            _queueLimitOrder(quote.finalToken.toAddress(), quote.finalRecipient.toAddress(), quote.amount);
        }
    }

    function _isQuoteEligibleForSwap(
        SponsoredCCTPInterface.SponsoredCCTPQuote memory quote,
        bytes memory signature
    ) internal view returns (bool) {
        return quote.burnToken != quote.finalToken && _isQuoteValid(quote, signature);
    }

    function _isQuoteValid(
        SponsoredCCTPInterface.SponsoredCCTPQuote memory quote,
        bytes memory signature
    ) internal view returns (bool) {
        return
            SponsoredCCTPQuoteLib.validateSignature(signer, quote, signature) &&
            !usedNonces[quote.nonce] &&
            quote.deadline >= block.timestamp &&
            quote.maxBpsToSponsor > 0;
    }

    function _getAccountActivationFee(address token, address recipient) internal view returns (uint256) {
        bool accountActivated = HyperCoreLib.coreUserExists(recipient);

        // fee for account activation is 1 token
        return accountActivated ? 0 : 10 ** IERC20Metadata(token).decimals();
    }

    function _queueLimitOrder(address token, address recipient, uint256 amount) internal {
        IERC20Metadata(token).safeTransfer(tokenCoreInfo[token].swapHandler, amount);
        // TODO: get the limit price from the quote
        uint64 limitPriceX1e8 = 10;
        uint64 sizeX1e8 = uint64(amount);

        SwapHandler(tokenCoreInfo[token].swapHandler).swap(
            tokenCoreInfo[token],
            recipient,
            amount,
            limitPriceX1e8,
            sizeX1e8
        );
    }

    // Only used for testing
    function sweepErc20(address token, address to, uint256 amount) external onlyOwner {
        IERC20Metadata(token).transfer(to, amount);
    }
}
