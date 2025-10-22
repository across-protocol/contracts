// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.23;

import { Quote } from "./Structs.sol";
import { QuoteSignLib } from "./QuoteSignLib.sol";
import { ComposeMsgCodec } from "./ComposeMsgCodec.sol";

import { IOFT, IOAppCore, SendParam, MessagingFee } from "../../../interfaces/IOFT.sol";
import { AddressToBytes32 } from "../../../libraries/AddressConverters.sol";
import { MinimalLZOptions } from "../../../external/libraries/MinimalLZOptions.sol";

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Source chain periphery contract for users to interact with to start a sponsored or a non-sponsored flow
/// that allows custom Accross-supported flows on destination chain. Uses LayzerZero's OFT as an underlying bridge
contract SponsoredOFTSrcPeriphery is Ownable {
    using AddressToBytes32 for address;
    using MinimalLZOptions for bytes;
    using SafeERC20 for IERC20;

    bytes public constant EMPTY_OFT_COMMAND = new bytes(0);

    /// @notice Token that's being sent by an OFT bridge
    address public immutable TOKEN;
    /// @notice OFT contract to interact with to initiate the bridge
    address public immutable OFT_MESSENGER;

    /// @notice Source endpoint id
    uint32 public immutable SRC_EID;

    /// @notice Signer public key to check the signed quote against
    address public signer;

    /// @notice A mapping to enforce only a single usage per quote
    mapping(bytes32 => bool) public quoteNonces;

    /// @notice Event with auxiliary information. To be used in concert with OftSent event to get relevant quote details
    event SponsoredOFTSend(
        bytes32 indexed quoteNonce,
        address indexed originSender,
        bytes32 indexed finalRecipient,
        bytes32 destinationHandler,
        uint256 quoteDeadline,
        uint256 maxBpsToSponsor,
        uint256 maxUserSlippageBps,
        bytes32 finalToken,
        bytes sig
    );

    /// @notice Thrown when the source eid of the ioft messenger does not match the src eid supplied
    error IncorrectSrcEid();
    /// @notice Thrown when the supplied token does not match the supplied ioft messenger
    error TokenIOFTMismatch();
    /// @notice Thrown when the signer for quote does not match `signer`
    error IncorrectSignature();
    /// @notice Thrown if Quote has expired
    error QuoteExpired();
    /// @notice Thrown if Quote nonce was already used
    error NonceAlreadyUsed();

    constructor(address _token, address _oftMessenger, uint32 _srcEid, address _signer) {
        TOKEN = _token;
        OFT_MESSENGER = _oftMessenger;
        SRC_EID = _srcEid;
        if (IOAppCore(_oftMessenger).endpoint().eid() != _srcEid) {
            revert IncorrectSrcEid();
        }
        if (IOFT(_oftMessenger).token() != _token) {
            revert TokenIOFTMismatch();
        }
        signer = _signer;
    }

    /// @notice Main entrypoint function to start the user flow
    function deposit(Quote calldata quote, bytes calldata signature) external payable {
        // Step 1: validate quote and mark quote nonce used
        _validateQuote(quote, signature);
        quoteNonces[quote.signedParams.nonce] = true;

        // Step 2: build oft send params from quote
        (SendParam memory sendParam, MessagingFee memory fee, address refundAddress) = _buildOftTransfer(quote);

        // Step 3: pull tokens from user and apporove OFT messenger
        IERC20(TOKEN).safeTransferFrom(msg.sender, address(this), quote.signedParams.amountLD);
        IERC20(TOKEN).forceApprove(address(OFT_MESSENGER), quote.signedParams.amountLD);

        // Step 4: send oft transfer and emit event with auxiliary data
        IOFT(OFT_MESSENGER).send{ value: msg.value }(sendParam, fee, refundAddress);
        emit SponsoredOFTSend(
            quote.signedParams.nonce,
            msg.sender,
            quote.signedParams.finalRecipient,
            quote.signedParams.destinationHandler,
            quote.signedParams.deadline,
            quote.signedParams.maxBpsToSponsor,
            quote.unsignedParams.maxUserSlippageBps,
            quote.signedParams.finalToken,
            signature
        );
    }

    function _buildOftTransfer(
        Quote calldata quote
    ) internal view returns (SendParam memory, MessagingFee memory, address) {
        bytes memory composeMsg = ComposeMsgCodec._encode(
            quote.signedParams.nonce,
            quote.signedParams.deadline,
            quote.signedParams.maxBpsToSponsor,
            quote.unsignedParams.maxUserSlippageBps,
            quote.signedParams.finalRecipient,
            quote.signedParams.finalToken,
            quote.signedParams.executionMode,
            quote.signedParams.actionData
        );

        bytes memory extraOptions = MinimalLZOptions
            .newOptions()
            .addExecutorLzReceiveOption(uint128(quote.signedParams.lzReceiveGasLimit), uint128(0))
            .addExecutorLzComposeOption(uint16(0), uint128(quote.signedParams.lzComposeGasLimit), uint128(0));

        SendParam memory sendParam = SendParam(
            quote.signedParams.dstEid,
            quote.signedParams.destinationHandler,
            // Only support OFT sends that don't take fees in sent token. Set `minAmountLD = amountLD` to enforce this
            quote.signedParams.amountLD,
            quote.signedParams.amountLD,
            extraOptions,
            composeMsg,
            // Only support empty OFT commands
            EMPTY_OFT_COMMAND
        );

        MessagingFee memory fee = IOFT(OFT_MESSENGER).quoteSend(sendParam, false);

        return (sendParam, fee, quote.unsignedParams.refundRecipient);
    }

    function _validateQuote(Quote calldata quote, bytes calldata signature) internal view {
        if (!QuoteSignLib.isSignatureValid(signer, quote.signedParams, signature)) {
            revert IncorrectSignature();
        }
        if (quote.signedParams.deadline < block.timestamp) {
            revert QuoteExpired();
        }
        if (quote.signedParams.srcEid != SRC_EID) {
            revert IncorrectSrcEid();
        }
        if (quoteNonces[quote.signedParams.nonce]) {
            revert NonceAlreadyUsed();
        }
    }

    function setSigner(address _newSigner) external onlyOwner {
        signer = _newSigner;
    }
}
