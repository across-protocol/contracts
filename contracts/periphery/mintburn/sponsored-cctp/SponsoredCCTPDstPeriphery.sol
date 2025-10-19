//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IMessageTransmitterV2 } from "../../../external/interfaces/CCTPInterfaces.sol";
import { SponsoredCCTPQuoteLib } from "../../../libraries/SponsoredCCTPQuoteLib.sol";
import { SponsoredCCTPInterface } from "../../../interfaces/SponsoredCCTPInterface.sol";
import { Bytes32ToAddress } from "../../../libraries/AddressConverters.sol";
import { HyperCoreFlowExecutor } from "../HyperCoreFlowExecutor.sol";

contract SponsoredCCTPDstPeriphery is SponsoredCCTPInterface, HyperCoreFlowExecutor {
    using SafeERC20 for IERC20Metadata;
    using Bytes32ToAddress for bytes32;

    /// @notice The CCTP message transmitter contract.
    IMessageTransmitterV2 public immutable cctpMessageTransmitter;

    /// @notice The public key of the signer that was used to sign the quotes.
    address public signer;

    /// @notice Allow a buffer for quote deadline validation. CCTP transfer might have taken a while to finalize
    uint256 public quoteDeadlineBuffer = 30 minutes;

    /// @notice A mapping of used nonces to prevent replay attacks.
    mapping(bytes32 => bool) public usedNonces;

    constructor(
        address _cctpMessageTransmitter,
        address _signer,
        address _donationBox,
        address _baseToken,
        uint32 _coreIndex,
        bool _canBeUsedForAccountActivation,
        uint64 _accountActivationFeeCore,
        uint64 _bridgeSafetyBufferCore
    )
        HyperCoreFlowExecutor(
            _donationBox,
            _baseToken,
            _coreIndex,
            _canBeUsedForAccountActivation,
            _accountActivationFeeCore,
            _bridgeSafetyBufferCore
        )
    {
        cctpMessageTransmitter = IMessageTransmitterV2(_cctpMessageTransmitter);
        signer = _signer;
    }

    function setSigner(address _signer) external onlyDefaultAdmin {
        signer = _signer;
    }

    function setQuoteDeadlineBuffer(uint256 _quoteDeadlineBuffer) external onlyDefaultAdmin {
        quoteDeadlineBuffer = _quoteDeadlineBuffer;
    }

    function receiveMessage(bytes memory message, bytes memory attestation, bytes memory signature) external {
        cctpMessageTransmitter.receiveMessage(message, attestation);

        // If the hook data is invalid or the mint recipient is not this contract we cannot process the message and therefore we return.
        // In this case the funds will be kept in this contract
        if (!SponsoredCCTPQuoteLib.validateMessage(message)) {
            return;
        }

        (SponsoredCCTPInterface.SponsoredCCTPQuote memory quote, uint256 feeExecuted) = SponsoredCCTPQuoteLib
            .getSponsoredCCTPQuoteData(message);

        bool isQuoteValid = _isQuoteValid(quote, signature);
        if (isQuoteValid) {
            usedNonces[quote.nonce] = true;
        }

        _executeFlow(
            quote.amount,
            quote.nonce,
            // If the quote is invalid we don't sponsor the flow or the extra fees
            isQuoteValid ? quote.maxBpsToSponsor : 0,
            quote.maxUserSlippageBps,
            quote.finalRecipient.toAddress(),
            // If the quote is invalid we don't want to swap, so we use the base token as the final token
            isQuoteValid ? quote.finalToken.toAddress() : baseToken,
            isQuoteValid ? feeExecuted : 0
        );

        emit SponsoredMintAndWithdraw(
            quote.nonce,
            quote.finalRecipient,
            quote.finalToken,
            quote.amount,
            quote.deadline,
            quote.maxBpsToSponsor,
            quote.maxUserSlippageBps
        );
    }

    function _isQuoteValid(
        SponsoredCCTPInterface.SponsoredCCTPQuote memory quote,
        bytes memory signature
    ) internal view returns (bool) {
        return
            SponsoredCCTPQuoteLib.validateSignature(signer, quote, signature) &&
            !usedNonces[quote.nonce] &&
            quote.deadline + quoteDeadlineBuffer >= block.timestamp;
    }
}
