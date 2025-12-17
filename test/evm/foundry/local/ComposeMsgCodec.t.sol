// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.23;

import { Test } from "forge-std/Test.sol";
import { ComposeMsgCodec } from "contracts/periphery/mintburn/sponsored-oft/ComposeMsgCodec.sol";

contract ComposeMsgCodecTest is Test {
    function test_EncodeDecode() public {
        bytes32 nonce = keccak256("nonce");
        uint256 deadline = 1234567890;
        uint256 maxBpsToSponsor = 500;
        uint256 maxUserSlippageBps = 100;
        bytes32 finalRecipient = keccak256("recipient");
        bytes32 finalToken = keccak256("token");
        uint32 destinationDex = 17;
        uint8 accountCreationMode = 5;
        uint8 executionMode = 7;
        bytes memory actionData = hex"deadbeef";

        bytes memory encoded = ComposeMsgCodec._encode(
            nonce,
            deadline,
            maxBpsToSponsor,
            maxUserSlippageBps,
            finalRecipient,
            finalToken,
            destinationDex,
            accountCreationMode,
            executionMode,
            actionData
        );

        assertEq(ComposeMsgCodec._getNonce(encoded), nonce, "Nonce mismatch");
        assertEq(ComposeMsgCodec._getDeadline(encoded), deadline, "Deadline mismatch");
        assertEq(ComposeMsgCodec._getMaxBpsToSponsor(encoded), maxBpsToSponsor, "MaxBpsToSponsor mismatch");
        assertEq(ComposeMsgCodec._getMaxUserSlippageBps(encoded), maxUserSlippageBps, "MaxUserSlippageBps mismatch");
        assertEq(ComposeMsgCodec._getFinalRecipient(encoded), finalRecipient, "FinalRecipient mismatch");
        assertEq(ComposeMsgCodec._getFinalToken(encoded), finalToken, "FinalToken mismatch");
        assertEq(ComposeMsgCodec._getDestinationDex(encoded), destinationDex, "DestinationDex mismatch");
        assertEq(ComposeMsgCodec._getAccountCreationMode(encoded), accountCreationMode, "AccountCreationMode mismatch");
        assertEq(ComposeMsgCodec._getExecutionMode(encoded), executionMode, "ExecutionMode mismatch");
        assertEq(ComposeMsgCodec._getActionData(encoded), actionData, "ActionData mismatch");
        assertTrue(ComposeMsgCodec._isValidComposeMsgBytelength(encoded), "Invalid length");
    }

    function testFuzz_EncodeDecode(
        bytes32 nonce,
        uint256 deadline,
        uint256 maxBpsToSponsor,
        uint256 maxUserSlippageBps,
        bytes32 finalRecipient,
        bytes32 finalToken,
        uint32 destinationDex,
        uint8 accountCreationMode,
        uint8 executionMode,
        bytes memory actionData
    ) public {
        bytes memory encoded = ComposeMsgCodec._encode(
            nonce,
            deadline,
            maxBpsToSponsor,
            maxUserSlippageBps,
            finalRecipient,
            finalToken,
            destinationDex,
            accountCreationMode,
            executionMode,
            actionData
        );

        assertEq(ComposeMsgCodec._getNonce(encoded), nonce, "Nonce mismatch");
        assertEq(ComposeMsgCodec._getDeadline(encoded), deadline, "Deadline mismatch");
        assertEq(ComposeMsgCodec._getMaxBpsToSponsor(encoded), maxBpsToSponsor, "MaxBpsToSponsor mismatch");
        assertEq(ComposeMsgCodec._getMaxUserSlippageBps(encoded), maxUserSlippageBps, "MaxUserSlippageBps mismatch");
        assertEq(ComposeMsgCodec._getFinalRecipient(encoded), finalRecipient, "FinalRecipient mismatch");
        assertEq(ComposeMsgCodec._getFinalToken(encoded), finalToken, "FinalToken mismatch");
        assertEq(ComposeMsgCodec._getDestinationDex(encoded), destinationDex, "DestinationDex mismatch");
        assertEq(ComposeMsgCodec._getAccountCreationMode(encoded), accountCreationMode, "AccountCreationMode mismatch");
        assertEq(ComposeMsgCodec._getExecutionMode(encoded), executionMode, "ExecutionMode mismatch");
        assertEq(ComposeMsgCodec._getActionData(encoded), actionData, "ActionData mismatch");
        assertTrue(ComposeMsgCodec._isValidComposeMsgBytelength(encoded), "Invalid length");
    }

    function test_IsValidComposeMsgBytelength_Boundary() public pure {
        // Minimum length is 352 bytes (9 static params + actionData offset + actionData length + 0 bytes actionData)
        // 9 * 32 + 32 + 32 = 352 bytes

        bytes memory data = new bytes(352);
        assertTrue(ComposeMsgCodec._isValidComposeMsgBytelength(data));

        bytes memory tooShort = new bytes(351);
        assertFalse(ComposeMsgCodec._isValidComposeMsgBytelength(tooShort));
    }
}
