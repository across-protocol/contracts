// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.23;
import { BytesLib } from "../../../libraries/BytesLib.sol";

/// @notice Codec for params passed in OFT `composeMsg`.
library ComposeMsgCodec {
    uint256 internal constant NONCE_OFFSET = 0;
    uint256 internal constant DEADLINE_OFFSET = 32;
    uint256 internal constant MAX_BPS_TO_SPONSOR_OFFSET = 64;
    uint256 internal constant MAX_USER_SLIPPAGE_BPS_OFFSET = 96;
    uint256 internal constant FINAL_RECIPIENT_OFFSET = 128;
    uint256 internal constant FINAL_TOKEN_OFFSET = 160;
    uint256 internal constant COMPOSE_MSG_BYTE_LENGTH = 192;

    function _encode(
        bytes32 nonce,
        uint256 deadline,
        uint256 maxBpsToSponsor,
        uint256 maxUserSlippageBps,
        bytes32 finalRecipient,
        bytes32 finalToken
    ) internal pure returns (bytes memory) {
        return abi.encode(nonce, deadline, maxBpsToSponsor, maxUserSlippageBps, finalRecipient, finalToken);
    }

    function _getNonce(bytes memory data) internal pure returns (bytes32 v) {
        return BytesLib.toBytes32(data, NONCE_OFFSET);
    }

    function _getDeadline(bytes memory data) internal pure returns (uint256 v) {
        return BytesLib.toUint256(data, DEADLINE_OFFSET);
    }

    function _getMaxBpsToSponsor(bytes memory data) internal pure returns (uint256 v) {
        return BytesLib.toUint256(data, MAX_BPS_TO_SPONSOR_OFFSET);
    }

    function _getMaxUserSlippageBps(bytes memory data) internal pure returns (uint256 v) {
        return BytesLib.toUint256(data, MAX_USER_SLIPPAGE_BPS_OFFSET);
    }

    function _getFinalRecipient(bytes memory data) internal pure returns (bytes32 v) {
        return BytesLib.toBytes32(data, FINAL_RECIPIENT_OFFSET);
    }

    function _getFinalToken(bytes memory data) internal pure returns (bytes32 v) {
        return BytesLib.toBytes32(data, FINAL_TOKEN_OFFSET);
    }

    function _isValidComposeMsgBytelength(bytes memory data) internal pure returns (bool valid) {
        valid = data.length == COMPOSE_MSG_BYTE_LENGTH;
    }
}
