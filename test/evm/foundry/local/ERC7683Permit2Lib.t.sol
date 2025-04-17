// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";

import { ERC7683Permit2Lib, AcrossOrderData, ACROSS_ORDER_DATA_TYPE_HASH } from "../../../../contracts/erc7683/ERC7683Permit2Lib.sol";
import { GaslessCrossChainOrder } from "../../../../contracts/erc7683/ERC7683.sol";

contract ERC7683Permit2LibTest is Test {
    GaslessCrossChainOrder order;
    AcrossOrderData acrossOrder;

    function setUp() public {
        order = GaslessCrossChainOrder({
            originSettler: makeAddr("originSettler"),
            user: makeAddr("user"),
            nonce: 123,
            originChainId: 1,
            openDeadline: 1000,
            fillDeadline: 2000,
            orderDataType: keccak256("orderDataType"),
            orderData: bytes("orderData")
        });
        acrossOrder = AcrossOrderData({
            inputToken: makeAddr("inputToken"),
            inputAmount: 1000,
            outputToken: makeAddr("outputToken"),
            outputAmount: 2000,
            destinationChainId: 2,
            recipient: bytes32("recipient"),
            exclusiveRelayer: makeAddr("exclusiveRelayer"),
            depositNonce: 1234,
            exclusivityPeriod: 3000,
            message: bytes("message")
        });
    }

    function testHashOrder() public {
        bytes32 orderDataHash = keccak256(order.orderData);
        bytes32 expectedHash = keccak256(
            abi.encode(
                ERC7683Permit2Lib.GASLESS_CROSS_CHAIN_ORDER_TYPE_HASH,
                order.originSettler,
                order.user,
                order.nonce,
                order.originChainId,
                order.openDeadline,
                order.fillDeadline,
                order.orderDataType,
                orderDataHash
            )
        );
        bytes32 actualHash = ERC7683Permit2Lib.hashOrder(order, orderDataHash);
        assertEq(expectedHash, actualHash);
    }

    function testHashOrderData() public {
        bytes32 expectedHash = keccak256(
            abi.encode(
                ACROSS_ORDER_DATA_TYPE_HASH,
                acrossOrder.inputToken,
                acrossOrder.inputAmount,
                acrossOrder.outputToken,
                acrossOrder.outputAmount,
                acrossOrder.destinationChainId,
                acrossOrder.recipient,
                acrossOrder.exclusiveRelayer,
                acrossOrder.depositNonce,
                acrossOrder.exclusivityPeriod,
                keccak256(acrossOrder.message)
            )
        );
        bytes32 actualHash = ERC7683Permit2Lib.hashOrderData(acrossOrder);
        assertEq(expectedHash, actualHash);
    }
}
