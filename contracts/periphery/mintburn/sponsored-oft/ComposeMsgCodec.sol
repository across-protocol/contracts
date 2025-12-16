// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.23;
import { BytesLib } from "../../../external/libraries/BytesLib.sol";

/// @notice Codec for params passed in OFT `composeMsg`.
library ComposeMsgCodec {
    // Minimum length with empty actionData: 8 regular params (32 bytes each) and 1 dynamic byte array (minumum 64 bytes)
    // 8 * 32 + 64 = 320
    uint256 internal constant MIN_COMPOSE_MSG_BYTE_LENGTH = 320;

    function _encode(
        bytes32 nonce,
        uint256 deadline,
        uint256 maxBpsToSponsor,
        uint256 maxUserSlippageBps,
        bytes32 finalRecipient,
        bytes32 finalToken,
        uint32 destinationDex,
        uint8 executionMode,
        uint8 accountCreationMode,
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
                destinationDex,
                executionMode,
                accountCreationMode,
                actionData
            );
    }

    function _getNonce(bytes memory data) internal pure returns (bytes32 v) {
        (v, , , , , , , , , ) = _decode(data);
    }

    function _getDeadline(bytes memory data) internal pure returns (uint256 v) {
        (, v, , , , , , , , ) = _decode(data);
    }

    function _getMaxBpsToSponsor(bytes memory data) internal pure returns (uint256 v) {
        (, , v, , , , , , , ) = _decode(data);
    }

    function _getMaxUserSlippageBps(bytes memory data) internal pure returns (uint256 v) {
        (, , , v, , , , , , ) = _decode(data);
    }

    function _getFinalRecipient(bytes memory data) internal pure returns (bytes32 v) {
        (, , , , v, , , , , ) = _decode(data);
    }

    function _getFinalToken(bytes memory data) internal pure returns (bytes32 v) {
        (, , , , , v, , , , ) = _decode(data);
    }

    function _getDestinationDex(bytes memory data) internal pure returns (uint32 v) {
        (, , , , , , v, , , ) = _decode(data);
    }

    function _getExecutionMode(bytes memory data) internal pure returns (uint8 v) {
        (, , , , , , , v, , ) = _decode(data);
    }

    function _getAccountCreationMode(bytes memory data) internal pure returns (uint8 v) {
        (, , , , , , , , v, ) = _decode(data);
    }

    function _getActionData(bytes memory data) internal pure returns (bytes memory v) {
        (, , , , , , , , , v) = _decode(data);
    }

    function _decode(
        bytes memory data
    )
        internal
        pure
        returns (
            bytes32 nonce,
            uint256 deadline,
            uint256 maxBpsToSponsor,
            uint256 maxUserSlippageBps,
            bytes32 finalRecipient,
            bytes32 finalToken,
            uint32 destinationDex,
            uint8 executionMode,
            uint8 accountCreationMode,
            bytes memory actionData
        )
    {
        (
            nonce,
            deadline,
            maxBpsToSponsor,
            maxUserSlippageBps,
            finalRecipient,
            finalToken,
            destinationDex,
            executionMode,
            accountCreationMode,
            actionData
        ) = abi.decode(data, (bytes32, uint256, uint256, uint256, bytes32, bytes32, uint32, uint8, uint8, bytes));
    }

    function _isValidComposeMsgBytelength(bytes memory data) internal pure returns (bool valid) {
        // Message must be at least the minimum length (can be longer due to variable actionData)
        valid = data.length >= MIN_COMPOSE_MSG_BYTE_LENGTH;
    }
}
