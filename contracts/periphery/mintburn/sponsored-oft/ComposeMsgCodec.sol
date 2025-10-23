// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.23;
import { BytesLib } from "../../../external/libraries/BytesLib.sol";

/// @notice Codec for params passed in OFT `composeMsg`.
library ComposeMsgCodec {
    uint256 internal constant NONCE_OFFSET = 0;
    uint256 internal constant DEADLINE_OFFSET = 32;
    uint256 internal constant MAX_BPS_TO_SPONSOR_OFFSET = 64;
    uint256 internal constant MAX_USER_SLIPPAGE_BPS_OFFSET = 96;
    uint256 internal constant FINAL_RECIPIENT_OFFSET = 128;
    uint256 internal constant FINAL_TOKEN_OFFSET = 160;
    uint256 internal constant EXECUTION_MODE_OFFSET = 192;
    // Minimum length with empty actionData: 7 regular params (32 bytes each) and 1 dynamic byte array (minumum 64 bytes)
    uint256 internal constant MIN_COMPOSE_MSG_BYTE_LENGTH = 288;

    function _encode(
        bytes32 nonce,
        uint256 deadline,
        uint256 maxBpsToSponsor,
        uint256 maxUserSlippageBps,
        bytes32 finalRecipient,
        bytes32 finalToken,
        uint8 executionMode,
        bytes memory actionData
    ) internal pure returns (bytes memory) {
        return
            abi.encode(
                nonce,
                deadline,
                maxBpsToSponsor,
                maxUserSlippageBps,
                finalRecipient,
                finalToken,
                executionMode,
                actionData
            );
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

    function _getExecutionMode(bytes memory data) internal pure returns (uint8 v) {
        (, , , , , , uint8 executionMode, ) = abi.decode(
            data,
            (bytes32, uint256, uint256, uint256, bytes32, bytes32, uint8, bytes)
        );
        return executionMode;
    }

    function _getActionData(bytes memory data) internal pure returns (bytes memory v) {
        (, , , , , , , bytes memory actionData) = abi.decode(
            data,
            (bytes32, uint256, uint256, uint256, bytes32, bytes32, uint8, bytes)
        );
        return actionData;
    }

    function _isValidComposeMsgBytelength(bytes memory data) internal pure returns (bool valid) {
        // Message must be at least the minimum length (can be longer due to variable actionData)
        valid = data.length >= MIN_COMPOSE_MSG_BYTE_LENGTH;
    }
}
