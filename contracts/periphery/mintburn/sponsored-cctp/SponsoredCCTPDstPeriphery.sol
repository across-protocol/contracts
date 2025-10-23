//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IMessageTransmitterV2 } from "../../../external/interfaces/CCTPInterfaces.sol";
import { SponsoredCCTPQuoteLib } from "../../../libraries/SponsoredCCTPQuoteLib.sol";
import { SponsoredCCTPInterface } from "../../../interfaces/SponsoredCCTPInterface.sol";
import { Bytes32ToAddress } from "../../../libraries/AddressConverters.sol";
import { HyperCoreFlowExecutor } from "../HyperCoreFlowExecutor.sol";
import { ArbitraryEVMFlowExecutor } from "../ArbitraryEVMFlowExecutor.sol";
import { CommonFlowParams, EVMFlowParams } from "../Structs.sol";

/**
 * @title SponsoredCCTPDstPeriphery
 * @notice Destination chain periphery contract that supports sponsored/non-sponsored CCTP deposits.
 * @dev This contract is used to receive tokens via CCTP and execute the flow accordingly.
 */
contract SponsoredCCTPDstPeriphery is SponsoredCCTPInterface, HyperCoreFlowExecutor, ArbitraryEVMFlowExecutor {
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

    /**
     * @notice Constructor for the SponsoredCCTPDstPeriphery contract.
     * @param _cctpMessageTransmitter The address of the CCTP message transmitter contract.
     * @param _signer The address of the signer that was used to sign the quotes.
     * @param _donationBox The address of the donation box contract. This is used to store funds that are used for sponsored flows.
     * @param _baseToken The address of the base token which would be the USDC on HyperEVM.
     * @param _multicallHandler The address of the multicall handler contract.
     */
    constructor(
        address _cctpMessageTransmitter,
        address _signer,
        address _donationBox,
        address _baseToken,
        address _multicallHandler
    ) HyperCoreFlowExecutor(_donationBox, _baseToken) ArbitraryEVMFlowExecutor(_multicallHandler) {
        cctpMessageTransmitter = IMessageTransmitterV2(_cctpMessageTransmitter);
        signer = _signer;
    }

    /**
     * @notice Sets the signer address that is used to validate the signatures of the quotes.
     * @param _signer The new signer address.
     */
    function setSigner(address _signer) external nonReentrant onlyDefaultAdmin {
        signer = _signer;
    }

    /**
     * @notice Sets the quote deadline buffer. This is used to prevent the quote from being used after it has expired.
     * @param _quoteDeadlineBuffer The new quote deadline buffer.
     */
    function setQuoteDeadlineBuffer(uint256 _quoteDeadlineBuffer) external nonReentrant onlyDefaultAdmin {
        quoteDeadlineBuffer = _quoteDeadlineBuffer;
    }

    /**
     * @notice Receives a message from CCTP and executes the flow accordingly. This function first calls the
     * CCTP message transmitter to receive the funds before validating the quote and executing the flow.
     * @param message The message that is received from CCTP.
     * @param attestation The attestation that is received from CCTP.
     * @param signature The signature of the quote.
     */
    function receiveMessage(
        bytes memory message,
        bytes memory attestation,
        bytes memory signature
    ) external nonReentrant {
        cctpMessageTransmitter.receiveMessage(message, attestation);

        // If the hook data is invalid or the mint recipient is not this contract we cannot process the message
        // and therefore we exit. In this case the funds will be kept in this contract.
        if (!SponsoredCCTPQuoteLib.validateMessage(message)) {
            return;
        }

        // Extract the quote and the fee that was executed from the message.
        (SponsoredCCTPInterface.SponsoredCCTPQuote memory quote, uint256 feeExecuted) = SponsoredCCTPQuoteLib
            .getSponsoredCCTPQuoteData(message);

        // Validate the quote and the signature.
        bool isQuoteValid = _isQuoteValid(quote, signature);
        if (isQuoteValid) {
            usedNonces[quote.nonce] = true;
        }

        uint256 amountAfterFees = quote.amount - feeExecuted;

        CommonFlowParams memory commonParams = CommonFlowParams({
            amountInEVM: amountAfterFees,
            quoteNonce: quote.nonce,
            finalRecipient: quote.finalRecipient.toAddress(),
            // If the quote is invalid we don't want to swap, so we use the base token as the final token
            finalToken: isQuoteValid ? quote.finalToken.toAddress() : baseToken,
            // If the quote is invalid we don't sponsor the flow or the extra fees
            maxBpsToSponsor: isQuoteValid ? quote.maxBpsToSponsor : 0,
            extraFeesIncurred: feeExecuted
        });

        // Route to appropriate execution based on executionMode
        if (
            isQuoteValid &&
            (quote.executionMode == uint8(ExecutionMode.ArbitraryActionsToCore) ||
                quote.executionMode == uint8(ExecutionMode.ArbitraryActionsToEVM))
        ) {
            // Execute flow with arbitrary evm actions
            _executeWithEVMFlow(
                EVMFlowParams({
                    commonParams: commonParams,
                    initialToken: baseToken,
                    actionData: quote.actionData,
                    transferToCore: quote.executionMode == uint8(ExecutionMode.ArbitraryActionsToCore)
                })
            );
        } else {
            // Execute standard HyperCore flow (default)
            HyperCoreFlowExecutor._executeFlow(commonParams, quote.maxUserSlippageBps);
        }
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

    function _executeWithEVMFlow(EVMFlowParams memory params) internal {
        params.commonParams = ArbitraryEVMFlowExecutor._executeFlow(params);

        // Route to appropriate destination based on transferToCore flag
        (params.transferToCore ? _executeSimpleTransferFlow : _fallbackHyperEVMFlow)(params.commonParams);
    }
}
