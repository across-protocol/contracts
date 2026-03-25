// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";

import { HyperCoreLib } from "../../../../contracts/libraries/HyperCoreLib.sol";

// Wrapper contract to expose internal library functions for testing
contract HyperCoreLibWrapper {
    function maximumEVMSendAmountToAmounts(
        uint256 maximumEVMSendAmount,
        int8 decimalDiff
    ) external pure returns (uint256 amountEVMToSend, uint64 amountCoreToReceive) {
        return HyperCoreLib.maximumEVMSendAmountToAmounts(maximumEVMSendAmount, decimalDiff);
    }
}

contract HyperCoreLibTest is Test {
    HyperCoreLibWrapper wrapper;

    function setUp() public {
        wrapper = new HyperCoreLibWrapper();
    }

    // ============ maximumEVMSendAmountToAmounts overflow tests ============

    // With decimalDiff == 0, Core amount equals EVM amount, so exceeding uint64.max reverts
    function testMaximumEVMSendAmountToAmounts_RevertsWhenCoreAmountExceedsUint64Max_ZeroDecimalDiff() public {
        uint256 tooLargeAmount = uint256(type(uint64).max) + 1;

        vm.expectRevert("SafeCast: value doesn't fit in 64 bits");
        wrapper.maximumEVMSendAmountToAmounts(tooLargeAmount, 0);
    }

    // With positive decimalDiff, Core amount = EVM / scale, so large EVM can still produce valid Core
    function testMaximumEVMSendAmountToAmounts_WorksWhenEVMExceedsUint64Max_PositiveDecimalDiff() public view {
        // EVM amount exceeds uint64.max but Core amount (after division) fits
        uint256 largeEVMAmount = uint256(type(uint64).max) + 1e6;
        int8 decimalDiff = 6;

        (uint256 amountEVMToSend, uint64 amountCoreToReceive) = wrapper.maximumEVMSendAmountToAmounts(
            largeEVMAmount,
            decimalDiff
        );

        // Core amount should be largeEVMAmount / 1e6, truncated for dust
        assertEq(amountEVMToSend, largeEVMAmount - (largeEVMAmount % 1e6));
        assertEq(amountCoreToReceive, uint64(amountEVMToSend / 1e6));
    }

    // With negative decimalDiff, Core amount = EVM * scale, can overflow even with smaller EVM values
    function testMaximumEVMSendAmountToAmounts_RevertsWhenCoreAmountExceedsUint64Max_NegativeDecimalDiff() public {
        // EVM amount that when scaled up exceeds uint64.max
        // uint64.max ~= 1.8e19, so with scale=1e6, any EVM amount > 1.8e13 will overflow
        uint256 evmAmount = uint256(type(uint64).max / 1e6) + 1; // Just over the limit
        int8 decimalDiff = -6;

        vm.expectRevert("SafeCast: value doesn't fit in 64 bits");
        wrapper.maximumEVMSendAmountToAmounts(evmAmount, decimalDiff);
    }

    // ============ maximumEVMSendAmountToAmounts boundary tests ============

    function testMaximumEVMSendAmountToAmounts_WorksAtUint64Max_ZeroDecimalDiff() public view {
        uint256 maxAmount = type(uint64).max;

        (uint256 amountEVMToSend, uint64 amountCoreToReceive) = wrapper.maximumEVMSendAmountToAmounts(maxAmount, 0);

        assertEq(amountEVMToSend, maxAmount);
        assertEq(amountCoreToReceive, type(uint64).max);
    }

    function testMaximumEVMSendAmountToAmounts_WorksAtBoundary_NegativeDecimalDiff() public view {
        // Maximum EVM amount that when scaled up equals exactly uint64.max
        uint256 evmAmount = type(uint64).max / 1e6;
        int8 decimalDiff = -6;

        (uint256 amountEVMToSend, uint64 amountCoreToReceive) = wrapper.maximumEVMSendAmountToAmounts(
            evmAmount,
            decimalDiff
        );

        assertEq(amountEVMToSend, evmAmount);
        assertEq(amountCoreToReceive, uint64(evmAmount * 1e6));
    }

    // ============ maximumEVMSendAmountToAmounts decimal conversion tests ============

    function testMaximumEVMSendAmountToAmounts_ZeroDecimalDiff() public view {
        uint256 amount = 1000e6;

        (uint256 amountEVMToSend, uint64 amountCoreToReceive) = wrapper.maximumEVMSendAmountToAmounts(amount, 0);

        assertEq(amountEVMToSend, amount);
        assertEq(amountCoreToReceive, uint64(amount));
    }

    function testMaximumEVMSendAmountToAmounts_PositiveDecimalDiff() public view {
        uint256 amount = 1000e12; // 1000 tokens with 12 decimals on EVM
        int8 decimalDiff = 6; // EVM 12 decimals, Core 6 decimals

        (uint256 amountEVMToSend, uint64 amountCoreToReceive) = wrapper.maximumEVMSendAmountToAmounts(
            amount,
            decimalDiff
        );

        assertEq(amountEVMToSend, amount);
        assertEq(amountCoreToReceive, uint64(1000e6));
    }

    function testMaximumEVMSendAmountToAmounts_TruncatesDust() public view {
        uint256 amount = 1000e12 + 123456; // Has dust (123456 < 1e6)
        int8 decimalDiff = 6;

        (uint256 amountEVMToSend, uint64 amountCoreToReceive) = wrapper.maximumEVMSendAmountToAmounts(
            amount,
            decimalDiff
        );

        assertEq(amountEVMToSend, 1000e12);
        assertEq(amountCoreToReceive, uint64(1000e6));
    }

    function testMaximumEVMSendAmountToAmounts_NegativeDecimalDiff() public view {
        uint256 amount = 1000;
        int8 decimalDiff = -6;

        (uint256 amountEVMToSend, uint64 amountCoreToReceive) = wrapper.maximumEVMSendAmountToAmounts(
            amount,
            decimalDiff
        );

        assertEq(amountEVMToSend, amount);
        assertEq(amountCoreToReceive, uint64(1000e6));
    }
}
