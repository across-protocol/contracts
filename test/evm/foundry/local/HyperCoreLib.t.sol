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

    // Test maximumEVMSendAmountToAmounts reverts when amount exceeds uint64 max
    function testMaximumEVMSendAmountToAmounts_RevertsWhenExceedsUint64Max() public {
        uint256 tooLargeAmount = uint256(type(uint64).max) + 1;

        vm.expectRevert(HyperCoreLib.MaximumEVMSendAmountTooLarge.selector);
        wrapper.maximumEVMSendAmountToAmounts(tooLargeAmount, 0);
    }

    function testMaximumEVMSendAmountToAmounts_RevertsWhenExceedsUint64Max_PositiveDecimalDiff() public {
        uint256 tooLargeAmount = uint256(type(uint64).max) + 1;

        vm.expectRevert(HyperCoreLib.MaximumEVMSendAmountTooLarge.selector);
        wrapper.maximumEVMSendAmountToAmounts(tooLargeAmount, 6);
    }

    function testMaximumEVMSendAmountToAmounts_RevertsWhenExceedsUint64Max_NegativeDecimalDiff() public {
        uint256 tooLargeAmount = uint256(type(uint64).max) + 1;

        vm.expectRevert(HyperCoreLib.MaximumEVMSendAmountTooLarge.selector);
        wrapper.maximumEVMSendAmountToAmounts(tooLargeAmount, -6);
    }

    // Test maximumEVMSendAmountToAmounts works at boundary (uint64 max)
    function testMaximumEVMSendAmountToAmounts_WorksAtUint64Max() public view {
        uint256 maxAmount = type(uint64).max;

        (uint256 amountEVMToSend, uint64 amountCoreToReceive) = wrapper.maximumEVMSendAmountToAmounts(maxAmount, 0);

        assertEq(amountEVMToSend, maxAmount);
        assertEq(amountCoreToReceive, type(uint64).max);
    }
}
