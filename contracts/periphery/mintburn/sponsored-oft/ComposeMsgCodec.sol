// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.23;
import { BytesLib } from "../../../libraries/BytesLib.sol";

/// @notice Codec for params passed in OFT `composeMsg`.
library ComposeMsgCodec {
    uint256 internal constant NONCE_OFFSET = 0;
    uint256 internal constant DEADLINE_OFFSET = 32;
    uint256 internal constant MAX_SPONSORSHIP_AMOUNT_OFFSET = 64;
    uint256 internal constant FINAL_RECIPIENT_OFFSET = 96;
    uint256 internal constant FINAL_TOKEN_OFFSET = 128;

    function _encode(
        bytes32 nonce,
        uint256 deadline,
        uint256 maxSponsorshipAmount,
        bytes32 finalRecipient,
        bytes32 finalToken
    ) internal pure returns (bytes memory) {
        return abi.encode(nonce, deadline, maxSponsorshipAmount, finalRecipient, finalToken);
    }

    function _getNonce(bytes memory data) internal pure returns (bytes32 v) {
        return BytesLib.toBytes32(data, NONCE_OFFSET);
    }

    function _getDeadline(bytes memory data) internal pure returns (uint256 v) {
        return BytesLib.toUint256(data, DEADLINE_OFFSET);
    }

    function _getMaxSponsorshipAmount(bytes memory data) internal pure returns (uint256 v) {
        return BytesLib.toUint256(data, MAX_SPONSORSHIP_AMOUNT_OFFSET);
    }

    function _getFinalRecipient(bytes memory data) internal pure returns (bytes32 v) {
        return BytesLib.toBytes32(data, FINAL_RECIPIENT_OFFSET);
    }

    function _getFinalToken(bytes memory data) internal pure returns (bytes32 v) {
        return BytesLib.toBytes32(data, FINAL_TOKEN_OFFSET);
    }
}
