// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts5/token/ERC20/IERC20.sol";
import { MulticallHandler } from "../../../../contracts/handlers/MulticallHandler.sol";

// Run this test to verify PermissionSplitter behavior when changing ownership of the HubPool
// to it. Therefore this test should be run as a fork test via:
// - source .env && forge test --fork-url $NODE_URL_1
contract MulticallHandlerTest is Test {
    MulticallHandler handler;
    MulticallHandler.Instructions instructions;
    address testEoa = address(0x123);
    bytes testBytes = abi.encodeWithSelector(TestTarget.callMe.selector, new bytes(7));
    uint256 testValue = 1;
    address testFallbackRecipient = address(0x456);
    address testToken = address(0x789);
    bytes handlerBalanceCall;
    bytes handlerTransferCall;

    TestTarget testTarget;

    function setUp() public {
        handler = new MulticallHandler();
        testTarget = new TestTarget();

        handlerBalanceCall = abi.encodeWithSelector(IERC20.balanceOf.selector, address(handler));
        handlerTransferCall = abi.encodeWithSelector(IERC20.transfer.selector, testFallbackRecipient, 5);

        vm.mockCall(testToken, handlerBalanceCall, abi.encode(5));
        vm.mockCall(testToken, handlerTransferCall, abi.encode(true));
    }

    function testNoFallback() public {
        vm.deal(address(handler), testValue * 2);
        instructions.calls.push(
            MulticallHandler.Call({ value: testValue, target: address(testTarget), callData: testBytes })
        );
        instructions.fallbackRecipient = address(0);

        vm.expectCall(address(testTarget), testValue, testBytes);
        handler.handleV3AcrossMessage(testToken, 0, address(0), abi.encode(instructions));

        vm.mockCallRevert(address(testTarget), testValue, testBytes, "");
        vm.expectRevert(abi.encodeWithSelector(MulticallHandler.CallReverted.selector, 0, instructions.calls));
        handler.handleV3AcrossMessage(testToken, 0, address(0), abi.encode(instructions));
    }

    function testFallback() public {
        vm.deal(address(handler), testValue * 2);
        instructions.calls.push(
            MulticallHandler.Call({ value: testValue, target: address(testTarget), callData: testBytes })
        );
        instructions.fallbackRecipient = testFallbackRecipient;

        vm.expectCall(address(testTarget), testValue, testBytes);
        vm.expectCall(testToken, handlerTransferCall);
        handler.handleV3AcrossMessage(testToken, 5, address(0), abi.encode(instructions));

        vm.mockCallRevert(address(testTarget), testValue, testBytes, "");
        vm.expectCall(testToken, handlerTransferCall);
        vm.expectEmit(false, false, false, true, address(handler));
        emit MulticallHandler.CallsFailed(instructions.calls, testFallbackRecipient);
        handler.handleV3AcrossMessage(testToken, 0, address(0), abi.encode(instructions));
    }

    function testInvalidCall() public {
        vm.deal(address(handler), testValue * 2);
        instructions.calls.push(MulticallHandler.Call({ value: testValue, target: testEoa, callData: testBytes }));
        instructions.fallbackRecipient = address(0);

        vm.expectRevert(abi.encodeWithSelector(MulticallHandler.InvalidCall.selector, 0, instructions.calls));
        handler.handleV3AcrossMessage(testToken, 0, address(0), abi.encode(instructions));
    }
}

contract TestTarget {
    constructor() {}

    function callMe(bytes calldata data) public payable returns (bytes memory) {
        return data;
    }
}
