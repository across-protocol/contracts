// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.23;

import { Quote } from "./Structs.sol";
import { QuoteSignLib } from "./QuoteSignLib.sol";
import { ComposeMsgCodec } from "./ComposeMsgCodec.sol";

import { IOFT, IOAppCore, IEndpoint, SendParam, MessagingFee } from "../../../interfaces/IOFT.sol";
import { AddressToBytes32 } from "../../../libraries/AddressConverters.sol";
import { MinimalLZOptions } from "../../../libraries/MinimalLZOptions.sol";

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Source chain periphery contract for users to interact with to start a sponsored or a non-sponsored flow
/// that allows custom Accross-supported flows on destination chain. Uses LayzerZero's OFT as an underlying bridge
contract SponsoredOFTSrcPeriphery is Ownable {
    using AddressToBytes32 for address;
    using MinimalLZOptions for bytes;
    using SafeERC20 for IERC20;

    bytes public constant EMPTY_MSG_BYTES = new bytes(0);

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
        uint256 quoteDeadline,
        uint256 maxBpsToSponsor,
        bytes32 finalToken,
        bytes sig
    );

    constructor(address _token, address _oftMessenger, address _signer, uint32 _srcEid) {
        TOKEN = _token;
        OFT_MESSENGER = _oftMessenger;
        require(IOFT(_oftMessenger).token() == _token, "Incorrect token <> ioft relationship");
        signer = _signer;
        require(IOAppCore(_oftMessenger).endpoint().eid() == _srcEid, "Incorrect srcEid");
        SRC_EID = _srcEid;
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
        IOFT(OFT_MESSENGER).send(sendParam, fee, refundAddress);
        emit SponsoredOFTSend(
            quote.signedParams.nonce,
            msg.sender,
            quote.signedParams.finalRecipient,
            quote.signedParams.deadline,
            quote.signedParams.maxBpsToSponsor,
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
            quote.signedParams.finalToken
        );

        bytes memory extraOptions = MinimalLZOptions
            .newOptions()
            .addExecutorLzReceiveOption(uint128(quote.unsignedParams.lzReceiveGasLimit), uint128(0))
            .addExecutorLzComposeOption(uint16(0), uint128(quote.unsignedParams.lzComposeGasLimit), uint128(0));

        SendParam memory sendParam = SendParam(
            quote.signedParams.dstEid,
            quote.signedParams.destinationHandler,
            // @dev We currently don't OFT sends that take fees in sent token, so set `minAmountLD = amountLD`
            quote.signedParams.amountLD,
            quote.signedParams.amountLD,
            extraOptions,
            composeMsg,
            // TODO? Is this an issue for ~classic tokens like USDT0?
            // Only support empty OFT commands
            EMPTY_MSG_BYTES
        );

        MessagingFee memory fee = IOFT(OFT_MESSENGER).quoteSend(sendParam, false);

        return (sendParam, fee, quote.unsignedParams.refundRecipient);
    }

    function _validateQuote(Quote calldata quote, bytes calldata signature) internal view {
        require(QuoteSignLib.isSignatureValid(signer, quote.signedParams, signature), "incorrect signature");
        require(quote.signedParams.deadline <= block.timestamp, "quote expired");
        require(quote.signedParams.srcEid == SRC_EID, "incorrect src eid");
        require(quoteNonces[quote.signedParams.nonce] == false, "quote nonce already used");
    }

    function setSigner(address _newSigner) external onlyOwner {
        signer = _newSigner;
    }
}
