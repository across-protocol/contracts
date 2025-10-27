//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IMessageTransmitterV2 } from "../../../external/interfaces/CCTPInterfaces.sol";
import { SponsoredCCTPInterface } from "../../../interfaces/SponsoredCCTPInterface.sol";
import { SponsoredCCTPMessageLib } from "../../../libraries/SponsoredCCTPMessageLib.sol";
import { HyperCoreFlowExecutor } from "../HyperCoreFlowExecutor.sol";
import { ArbitraryEVMFlowExecutor } from "../ArbitraryEVMFlowExecutor.sol";
import { EVMFlowParams } from "../Structs.sol";

/**
 * @title SponsoredCCTPDstPeriphery
 * @notice Destination chain periphery contract that supports sponsored/non-sponsored CCTP deposits.
 * @dev This contract is used to receive tokens via CCTP and execute the flow accordingly.
 */
contract SponsoredCCTPDstPeriphery is SponsoredCCTPInterface, HyperCoreFlowExecutor {
    using SafeERC20 for IERC20Metadata;

    /// @notice The CCTP message transmitter contract.
    IMessageTransmitterV2 public immutable cctpMessageTransmitter;

    /// @notice The multicall handler contract for arbitrary EVM actions.
    address public immutable multicallHandler;

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
    ) HyperCoreFlowExecutor(_donationBox, _baseToken) {
        cctpMessageTransmitter = IMessageTransmitterV2(_cctpMessageTransmitter);
        multicallHandler = _multicallHandler;
        signer = _signer;
    }

    /**
     * @notice Sets the signer address that is used to validate the signatures of the quotes.
     * @param _signer The new signer address.
     */
    function setSigner(address _signer) external nonReentrant {
        if (!hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) revert NotDefaultAdmin();
        signer = _signer;
    }

    /**
     * @notice Sets the quote deadline buffer. This is used to prevent the quote from being used after it has expired.
     * @param _quoteDeadlineBuffer The new quote deadline buffer.
     */
    function setQuoteDeadlineBuffer(uint256 _quoteDeadlineBuffer) external nonReentrant {
        if (!hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) revert NotDefaultAdmin();
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

        SponsoredCCTPMessageLib.MessageProcessingResult memory result = SponsoredCCTPMessageLib.processMessage(
            message,
            signature,
            signer,
            baseToken,
            quoteDeadlineBuffer
        );

        if (!result.shouldProcess) return;

        // Check nonce and update validity
        if (usedNonces[result.commonParams.quoteNonce]) {
            result.isQuoteValid = false;
        } else if (result.isQuoteValid) {
            usedNonces[result.commonParams.quoteNonce] = true;
        }

        if (
            result.isQuoteValid &&
            (result.executionMode == uint8(ExecutionMode.ArbitraryActionsToCore) ||
                result.executionMode == uint8(ExecutionMode.ArbitraryActionsToEVM))
        ) {
            EVMFlowParams memory evmParams = EVMFlowParams({
                commonParams: result.commonParams,
                initialToken: baseToken,
                actionData: result.actionData,
                transferToCore: result.executionMode == uint8(ExecutionMode.ArbitraryActionsToCore)
            });
            evmParams.commonParams = ArbitraryEVMFlowExecutor.executeFlow(multicallHandler, evmParams);
            (evmParams.transferToCore ? _executeSimpleTransferFlow : _fallbackHyperEVMFlow)(evmParams.commonParams);
        } else {
            HyperCoreFlowExecutor._executeFlow(result.commonParams, result.maxUserSlippageBps);
        }
    }

    /// @notice Allow contract to receive native tokens for arbitrary action execution
    receive() external payable {}
}
