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
import { CoreTokenInfo, LimitOrder } from "../Structs.sol";

contract SponsoredCCTPDstPeriphery is SponsoredCCTPInterface, Ownable {
    using SafeERC20 for IERC20Metadata;
    using Bytes32ToAddress for bytes32;

    /// @notice The CCTP message transmitter contract.
    IMessageTransmitterV2 public immutable cctpMessageTransmitter;

    /// @notice The public key of the signer that was used to sign the quotes.
    address public signer;

    /// @notice A mapping of used nonces to prevent replay attacks.
    mapping(bytes32 => bool) public usedNonces;

    /// @notice A mapping of token addresses to their core token info.
    mapping(address => CoreTokenInfo) public coreTokenInfos;

    /// @notice A mapping of token addresses to their swap handler address.
    mapping(address => address) public swapHandlers;

    LimitOrder[] public limitOrdersQueued;

    constructor(address _cctpMessageTransmitter, address _signer) {
        cctpMessageTransmitter = IMessageTransmitterV2(_cctpMessageTransmitter);
        signer = _signer;
    }

    function setSigner(address _signer) external onlyOwner {
        signer = _signer;
    }

    function setCoreTokenInfo(
        address evmContract,
        uint32 erc20CoreIndex,
        bool canBeUsedForAccountActivation,
        uint256 accountActivationFee
    ) external onlyOwner {
        HyperCoreLib.TokenInfo memory tokenInfo = HyperCoreLib.tokenInfo(erc20CoreIndex);
        coreTokenInfos[evmContract] = CoreTokenInfo({
            tokenInfo: tokenInfo,
            coreIndex: erc20CoreIndex,
            canBeUsedForAccountActivation: canBeUsedForAccountActivation,
            accountActivationFee: accountActivationFee
        });
    }

    function receiveMessage(bytes memory message, bytes memory attestation, bytes memory signature) external {
        cctpMessageTransmitter.receiveMessage(message, attestation);

        // If the hook data is invalid we cannot process the message and therefore we return.
        // In this case the funds will be kept in this contract
        if (!SponsoredCCTPQuoteLib.validateMessage(message)) {
            return;
        }

        (SponsoredCCTPInterface.SponsoredCCTPQuote memory quote, uint256 feeExecuted) = SponsoredCCTPQuoteLib
            .getSponsoredCCTPQuoteData(message);

        if (!_isQuoteValid(quote, signature)) {
            // If the quote is not valid, we execute a simple transfer regardless of the final token
            _executeSimpleTransfer(
                quote.amount,
                quote.finalRecipient.toAddress(),
                quote.burnToken.toAddress(),
                feeExecuted,
                0 // No basis points to sponsor
            );
        } else if (quote.burnToken != quote.finalToken) {
            _executeSimpleTransfer(
                quote.amount,
                quote.finalRecipient.toAddress(),
                quote.finalToken.toAddress(),
                feeExecuted,
                quote.maxBpsToSponsor
            );
        } else {
            _queueLimitOrder(quote.finalToken.toAddress(), quote.finalRecipient.toAddress(), quote.amount);
        }

        emit SponsoredMintAndWithdraw(
            quote.nonce,
            quote.finalRecipient,
            quote.finalToken,
            quote.amount,
            quote.deadline,
            quote.maxBpsToSponsor
        );
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

        // TODO: handle the case where the token can't be used for account activation
        return accountActivated ? 0 : coreTokenInfos[token].accountActivationFee;
    }

    function _executeSimpleTransfer(
        uint256 amount,
        address finalRecipient,
        address finalToken,
        uint256 feeExecuted,
        uint256 maxBpsToSponsor
    ) internal {
        uint256 maxFee = (amount * maxBpsToSponsor) / 10000;
        uint256 accountActivationFee = _getAccountActivationFee(finalToken, finalRecipient);
        uint256 maxAmountToSponsor = feeExecuted + accountActivationFee;
        if (maxAmountToSponsor > maxFee) {
            maxAmountToSponsor = maxFee;
        }

        uint256 finalAmount = amount + maxAmountToSponsor;

        // TODO: pull funds from donation box

        HyperCoreLib.transferERC20EVMToCore(
            finalToken,
            coreTokenInfos[finalToken].coreIndex,
            finalRecipient,
            finalAmount,
            coreTokenInfos[finalToken].tokenInfo.evmExtraWeiDecimals
        );

        emit SimpleTansferToCore(finalToken, finalRecipient, finalAmount, maxAmountToSponsor);
    }

    function _queueLimitOrder(address token, address recipient, uint256 amount) internal {
        // TODO: send the funds to the swap handler before queuing the limit order
        // TODO: get the limit price from the quote
        uint64 limitPriceX1e8 = 10;
        uint64 sizeX1e8 = uint64(amount);

        SwapHandler(swapHandlers[token]).submitLimitOrder(
            coreTokenInfos[token],
            recipient,
            amount,
            limitPriceX1e8,
            sizeX1e8,
            uint128(limitOrdersQueued.length)
        );
        limitOrdersQueued.push(
            LimitOrder({ cloid: uint128(limitOrdersQueued.length), limitPriceX1e8: limitPriceX1e8, sizeX1e8: sizeX1e8 })
        );
    }

    // Only used for testing
    function sweepErc20(address token, address to, uint256 amount) external onlyOwner {
        IERC20Metadata(token).transfer(to, amount);
    }
}
