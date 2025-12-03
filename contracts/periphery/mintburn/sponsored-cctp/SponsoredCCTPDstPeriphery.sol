//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

import { BaseModuleHandler } from "../BaseModuleHandler.sol";
import { IMessageTransmitterV2 } from "../../../external/interfaces/CCTPInterfaces.sol";
import { SponsoredCCTPQuoteLib } from "../../../libraries/SponsoredCCTPQuoteLib.sol";
import { SponsoredCCTPInterface } from "../../../interfaces/SponsoredCCTPInterface.sol";
import { Bytes32ToAddress } from "../../../libraries/AddressConverters.sol";
import { HyperCoreFlowExecutor } from "../HyperCoreFlowExecutor.sol";
import { ArbitraryEVMFlowExecutor } from "../ArbitraryEVMFlowExecutor.sol";
import { CommonFlowParams, EVMFlowParams } from "../Structs.sol";

import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title SponsoredCCTPDstPeriphery
 * @notice Destination chain periphery contract that supports sponsored/non-sponsored CCTP deposits.
 * @dev This contract is used to receive tokens via CCTP and execute the flow accordingly.
 * @dev IMPORTANT. `BaseModuleHandler` should always be the first contract in inheritance chain. Read 
    `BaseModuleHandler` contract code to learn more.
 */
contract SponsoredCCTPDstPeriphery is BaseModuleHandler, SponsoredCCTPInterface, ArbitraryEVMFlowExecutor {
    using SafeERC20 for IERC20Metadata;
    using Bytes32ToAddress for bytes32;

    /// @notice The CCTP message transmitter contract.
    IMessageTransmitterV2 public immutable cctpMessageTransmitter;

    /// @notice Base token associated with this handler. The one we receive from the CCTP bridge
    address public immutable baseToken;

    /// @custom:storage-location erc7201:SponsoredCCTPDstPeriphery.main
    struct MainStorage {
        /// @notice The public key of the signer that was used to sign the quotes.
        address signer;
        /// @notice Allow a buffer for quote deadline validation. CCTP transfer might have taken a while to finalize
        uint256 quoteDeadlineBuffer;
        /// @notice A mapping of used nonces to prevent replay attacks.
        mapping(bytes32 => bool) usedNonces;
    }

    // keccak256(abi.encode(uint256(keccak256("erc7201:SponsoredCCTPDstPeriphery.main")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant MAIN_STORAGE_LOCATION = 0xb788edf5b6d001c4df53cb371352fd225afa05a1712075d5f89a08d6b6f79f00;

    function _getMainStorage() private pure returns (MainStorage storage $) {
        assembly {
            $.slot := MAIN_STORAGE_LOCATION
        }
    }

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
    ) BaseModuleHandler(_donationBox, _baseToken, DEFAULT_ADMIN_ROLE) ArbitraryEVMFlowExecutor(_multicallHandler) {
        baseToken = _baseToken;

        cctpMessageTransmitter = IMessageTransmitterV2(_cctpMessageTransmitter);

        MainStorage storage $ = _getMainStorage();
        $.signer = _signer;
        $.quoteDeadlineBuffer = 30 minutes;

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    /**
     * @notice Returns the signer address that is used to validate the signatures of the quotes.
     * @return The signer address.
     */
    function signer() external view returns (address) {
        return _getMainStorage().signer;
    }

    /**
     * @notice Returns the quote deadline buffer.
     * @return The quote deadline buffer.
     */
    function quoteDeadlineBuffer() external view returns (uint256) {
        return _getMainStorage().quoteDeadlineBuffer;
    }

    /**
     * @notice Returns true if the nonce has been used, false otherwise.
     * @param nonce The nonce to check.
     * @return True if the nonce has been used, false otherwise.
     */
    function usedNonces(bytes32 nonce) external view returns (bool) {
        return _getMainStorage().usedNonces[nonce];
    }

    /**
     * @notice Sets the signer address that is used to validate the signatures of the quotes.
     * @param _signer The new signer address.
     */
    function setSigner(address _signer) external nonReentrant onlyRole(DEFAULT_ADMIN_ROLE) {
        _getMainStorage().signer = _signer;
    }

    /**
     * @notice Sets the quote deadline buffer. This is used to prevent the quote from being used after it has expired.
     * @param _quoteDeadlineBuffer The new quote deadline buffer.
     */
    function setQuoteDeadlineBuffer(uint256 _quoteDeadlineBuffer) external nonReentrant onlyRole(DEFAULT_ADMIN_ROLE) {
        _getMainStorage().quoteDeadlineBuffer = _quoteDeadlineBuffer;
    }

    /**
     * @notice Emmergency function that can be used to recover funds in cases where it is not possible to go
     * through the normal flow (e.g. HyperEVM <> HyperCore USDC bridge is blacklisted). Receives the message from
     * CCTP and then sends it to final recipient
     * @param message The message that is received from CCTP.
     * @param attestation The attestation that is received from CCTP.
     */
    function emergencyReceiveMessage(
        bytes memory message,
        bytes memory attestation
    ) external nonReentrant onlyRole(PERMISSIONED_BOT_ROLE) {
        bool success = cctpMessageTransmitter.receiveMessage(message, attestation);
        if (!success) {
            return;
        }

        // Use try-catch to handle potential abi.decode reverts gracefully
        try this.validateMessage(message) returns (bool isValid) {
            if (!isValid) {
                return;
            }
        } catch {
            // Malformed message that causes abi.decode to revert then early return
            return;
        }
        (SponsoredCCTPInterface.SponsoredCCTPQuote memory quote, uint256 feeExecuted) = SponsoredCCTPQuoteLib
            .getSponsoredCCTPQuoteData(message);

        _getMainStorage().usedNonces[quote.nonce] = true;

        IERC20Metadata(baseToken).safeTransfer(quote.finalRecipient.toAddress(), quote.amount - feeExecuted);

        emit EmergencyReceiveMessage(
            quote.nonce,
            quote.finalRecipient.toAddress(),
            baseToken,
            quote.amount - feeExecuted
        );
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
    ) external nonReentrant authorizeFundedFlow {
        bool success = cctpMessageTransmitter.receiveMessage(message, attestation);
        if (!success) {
            revert CCTPMessageTransmitterFailed();
        }

        // If the hook data is invalid or the mint recipient is not this contract we cannot process the message
        // and therefore we exit. In this case the funds will be kept in this contract.
        // Use try-catch to handle potential abi.decode reverts gracefully
        try this.validateMessage(message) returns (bool isValid) {
            if (!isValid) {
                return;
            }
        } catch {
            // Malformed message that causes abi.decode to revert then early return
            return;
        }
        // Extract the quote and the fee that was executed from the message.
        (SponsoredCCTPInterface.SponsoredCCTPQuote memory quote, uint256 feeExecuted) = SponsoredCCTPQuoteLib
            .getSponsoredCCTPQuoteData(message);

        // Validate the quote and the signature.
        bool isQuoteValid = _isQuoteValid(quote, signature);
        if (isQuoteValid) {
            _getMainStorage().usedNonces[quote.nonce] = true;
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
            // Execute standard HyperCore flow (default) via delegatecall
            _delegateToHyperCore(
                abi.encodeCall(HyperCoreFlowExecutor.executeFlow, (commonParams, quote.maxUserSlippageBps))
            );
        }
    }

    /**
     * @notice External wrapper for validateMessage to enable try-catch for safe abi.decode handling
     * @param message The CCTP message to validate
     * @return True if the message is valid, false otherwise
     */
    function validateMessage(bytes memory message) external view returns (bool) {
        return SponsoredCCTPQuoteLib.validateMessage(message);
    }

    function _isQuoteValid(
        SponsoredCCTPInterface.SponsoredCCTPQuote memory quote,
        bytes memory signature
    ) internal view returns (bool) {
        MainStorage storage $ = _getMainStorage();
        return
            SponsoredCCTPQuoteLib.validateSignature($.signer, quote, signature) &&
            !$.usedNonces[quote.nonce] &&
            quote.deadline + $.quoteDeadlineBuffer >= block.timestamp;
    }

    function _executeWithEVMFlow(EVMFlowParams memory params) internal {
        params.commonParams = ArbitraryEVMFlowExecutor._executeFlow(params);

        // Route to appropriate destination based on transferToCore flag
        _delegateToHyperCore(
            params.transferToCore
                ? abi.encodeCall(HyperCoreFlowExecutor.executeSimpleTransferFlow, (params.commonParams))
                : abi.encodeCall(HyperCoreFlowExecutor.fallbackHyperEVMFlow, (params.commonParams))
        );
    }
}
