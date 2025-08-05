// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";
import { MulticallHandler } from "../../../../contracts/handlers/MulticallHandler.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

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
    TokenTestTarget tokenTestTarget;
    BalanceTestTarget balanceTestTarget;

    function setUp() public {
        handler = new MulticallHandler();
        testTarget = new TestTarget();
        tokenTestTarget = new TokenTestTarget();
        balanceTestTarget = new BalanceTestTarget();

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

    /* Tests for makeCallWithBalance functionality */

    function testMakeCallWithBalanceOnlySelf() public {
        // Should revert when not called by the contract itself
        bytes memory callData = abi.encodeWithSelector(
            TokenTestTarget.transferToken.selector,
            testToken,
            address(0x999),
            100
        );
        MulticallHandler.Replacement[] memory replacements = new MulticallHandler.Replacement[](0);

        vm.expectRevert(MulticallHandler.NotSelf.selector);
        handler.makeCallWithBalance(address(tokenTestTarget), callData, 0, replacements);
    }

    function testCalldataTooShort() public {
        // Prepare a call with too short calldata
        bytes memory shortCallData = abi.encodePacked(bytes4(0x12345678)); // Just a 4-byte selector

        // Position beyond the calldata length
        uint256 invalidOffset = 20; // This is past the end of our calldata

        MulticallHandler.Replacement[] memory replacements = new MulticallHandler.Replacement[](1);
        replacements[0] = MulticallHandler.Replacement({ token: testToken, offset: invalidOffset });

        // Execute the test through a special call from the contract to itself to bypass onlySelf modifier
        bytes memory selfCallData = abi.encodeWithSelector(
            handler.makeCallWithBalance.selector,
            address(tokenTestTarget),
            shortCallData,
            0,
            replacements
        );

        // Create instructions to call the makeCallWithBalance function via handleV3AcrossMessage
        instructions = MulticallHandler.Instructions({
            calls: new MulticallHandler.Call[](1),
            fallbackRecipient: address(0)
        });
        instructions.calls[0] = MulticallHandler.Call({ target: address(handler), callData: selfCallData, value: 0 });

        // The error gets wrapped in a CallReverted error since it happens within a call initiated by
        // handleV3AcrossMessage, rather than directly
        vm.expectRevert(abi.encodeWithSelector(MulticallHandler.CallReverted.selector, 0, instructions.calls));
        handler.handleV3AcrossMessage(testToken, 0, address(0), abi.encode(instructions));
    }

    function testReplacementCallFailed() public {
        // Prepare a call that will fail
        bytes memory callData = abi.encodeWithSelector(TokenTestTarget.failingFunction.selector);

        MulticallHandler.Replacement[] memory replacements = new MulticallHandler.Replacement[](0);

        // Execute the test through a special call from the contract to itself to bypass onlySelf modifier
        bytes memory selfCallData = abi.encodeWithSelector(
            handler.makeCallWithBalance.selector,
            address(tokenTestTarget),
            callData,
            0,
            replacements
        );

        // Create instructions to call the makeCallWithBalance function via handleV3AcrossMessage
        instructions = MulticallHandler.Instructions({
            calls: new MulticallHandler.Call[](1),
            fallbackRecipient: address(0)
        });
        instructions.calls[0] = MulticallHandler.Call({ target: address(handler), callData: selfCallData, value: 0 });

        // The error gets wrapped in a CallReverted error since it happens within a call initiated by
        // handleV3AcrossMessage, rather than directly
        vm.expectRevert(abi.encodeWithSelector(MulticallHandler.CallReverted.selector, 0, instructions.calls));
        handler.handleV3AcrossMessage(testToken, 0, address(0), abi.encode(instructions));
    }

    function testMakeCallWithBalanceWithReplacement() public {
        address target = address(new SimpleMockTarget());

        MulticallHandler.Replacement[] memory replacements = new MulticallHandler.Replacement[](1);
        replacements[0] = MulticallHandler.Replacement({
            token: testToken,
            offset: 4 // 4 bytes for selector
        });

        // Execute the test through a special call from the contract to itself to bypass onlySelf modifier
        bytes memory selfCallData = abi.encodeWithSelector(
            handler.makeCallWithBalance.selector,
            address(target),
            abi.encodeWithSelector(SimpleMockTarget.setValue.selector, 0),
            0,
            replacements
        );

        // Create instructions to call the makeCallWithBalance function via handleV3AcrossMessage
        instructions = MulticallHandler.Instructions({
            calls: new MulticallHandler.Call[](1),
            fallbackRecipient: address(0)
        });
        instructions.calls[0] = MulticallHandler.Call({ target: address(handler), callData: selfCallData, value: 0 });

        vm.expectCall(address(target), abi.encodeWithSelector(SimpleMockTarget.setValue.selector, 5));
        handler.handleV3AcrossMessage(testToken, 0, address(0), abi.encode(instructions));

        assertEq(SimpleMockTarget(target).getValue(), 5);
    }

    function testMakeCallWithBalanceWithEthReplacement() public {
        // Create a direct approach using a special check target that verifies both
        // ETH transfer and value replacement
        EthStorageTarget target = new EthStorageTarget();

        // Fund the handler with ETH
        uint256 ethAmount = 2 ether;
        vm.deal(address(handler), ethAmount);

        // Create a simple call to the target - we'll replace offset 36 which will hit
        // the parameter after the selector+length in the abi encoding
        bytes memory targetCallData = abi.encodeWithSelector(
            EthStorageTarget.recordEthAndCheck.selector,
            uint256(0) // Will be replaced with ETH balance
        );

        // Set up the replacement structure using address(0) for ETH
        MulticallHandler.Replacement[] memory replacements = new MulticallHandler.Replacement[](1);
        replacements[0] = MulticallHandler.Replacement({
            token: address(0), // Use ETH balance
            offset: 4 // Position right after selector
        });

        // Create the call to makeCallWithBalance
        bytes memory selfCallData = abi.encodeWithSelector(
            handler.makeCallWithBalance.selector,
            address(target),
            targetCallData,
            0, // Will be replaced with all ETH
            replacements
        );

        // Set up instructions for handleV3AcrossMessage
        instructions = MulticallHandler.Instructions({
            calls: new MulticallHandler.Call[](1),
            fallbackRecipient: address(0)
        });
        instructions.calls[0] = MulticallHandler.Call({ target: address(handler), callData: selfCallData, value: 0 });

        // Execute the test
        handler.handleV3AcrossMessage(testToken, 0, address(0), abi.encode(instructions));

        // Our target contract already checked the values for us, but lets's verify again
        assertEq(address(target).balance, ethAmount, "Target did not receive the handler's ETH");
        assertEq(address(handler).balance, 0, "Handler still has ETH");
        assertEq(target.storedValue(), ethAmount, "ETH balance was not correctly replaced in calldata");
        assertTrue(target.checkPassed(), "Target contract's check failed");
    }

    function testMakeCallWithMultipleReplacements() public {
        // Create a new target for testing multiple replacements
        MultipleReplacementTarget target = new MultipleReplacementTarget();

        // Set up mock token behavior
        address token1 = address(0xABC); // First token
        address token2 = testToken; // Second token (reuse testToken for simplicity)

        // Define token balances
        uint256 token1Balance = 1000;
        uint256 token2Balance = 5; // Same as the mocked balance of testToken

        // Set up mock for token1 balance call
        bytes memory token1BalanceCall = abi.encodeWithSelector(IERC20.balanceOf.selector, address(handler));
        vm.mockCall(token1, token1BalanceCall, abi.encode(token1Balance));

        // Set up multiple replacements
        MulticallHandler.Replacement[] memory replacements = new MulticallHandler.Replacement[](2);
        replacements[0] = MulticallHandler.Replacement({
            token: token1,
            offset: 4 // Position for first parameter (right after selector)
        });
        replacements[1] = MulticallHandler.Replacement({
            token: token2,
            offset: 36 // Position for second parameter (4 + 32 bytes)
        });

        // Create the call to makeCallWithBalance with two replacements
        bytes memory selfCallData = abi.encodeWithSelector(
            handler.makeCallWithBalance.selector,
            address(target),
            abi.encodeWithSelector(
                MultipleReplacementTarget.setValues.selector,
                uint256(0), // Will be replaced with token1 balance
                uint256(0) // Will be replaced with token2 balance
            ),
            0, // No ETH value needed
            replacements
        );

        // Set up instructions for handleV3AcrossMessage
        instructions = MulticallHandler.Instructions({
            calls: new MulticallHandler.Call[](1),
            fallbackRecipient: address(0)
        });
        instructions.calls[0] = MulticallHandler.Call({ target: address(handler), callData: selfCallData, value: 0 });

        // Expect the target to be called with both token balances as arguments
        vm.expectCall(
            address(target),
            abi.encodeWithSelector(MultipleReplacementTarget.setValues.selector, token1Balance, token2Balance)
        );

        // Execute the test
        handler.handleV3AcrossMessage(testToken, 0, address(0), abi.encode(instructions));

        // Verify both values were set correctly in the target
        assertEq(target.value1(), token1Balance, "Token1 balance not correctly replaced");
        assertEq(target.value2(), token2Balance, "Token2 balance not correctly replaced");
    }
}

contract TestTarget {
    constructor() {}

    function callMe(bytes calldata data) public payable returns (bytes memory) {
        return data;
    }
}

contract TokenTestTarget {
    function transferToken(address token, address recipient, uint256 amount) public returns (bool) {
        return IERC20(token).transfer(recipient, amount);
    }

    function failingFunction() public pure {
        revert("This function always fails");
    }
}

contract BalanceTestTarget {
    uint256 private _storedAmount;

    function storeAmount(uint256 amount) public payable {
        _storedAmount = amount;
    }

    function getStoredAmount() public view returns (uint256) {
        return _storedAmount;
    }
}

contract SimpleMockTarget {
    uint256 private _value;

    function setValue(uint256 value) public {
        _value = value;
    }

    function getValue() public view returns (uint256) {
        return _value;
    }
}

/**
 * @notice Target for ETH replacement testing that verifies both
 * replacement value and ETH sending in the same call
 */
contract EthStorageTarget {
    uint256 private _storedValue;
    bool private _checkPassed;

    /**
     * @notice Record the ETH balance as parameter and verify ETH was sent
     * This function also verifies that the received value matches both the message
     * value and the first parameter
     * @param expectedAmount The amount we expect to receive, should be replaced with handler's ETH balance
     */
    function recordEthAndCheck(uint256 expectedAmount) external payable {
        // Store the received parameter
        _storedValue = expectedAmount;

        // Check if the expected value matches what was sent (handler's full ETH balance)
        // AND if the msg.value matches the expected amount (handler's full ETH balance)
        _checkPassed = (expectedAmount == msg.value && msg.value > 0);
    }

    // Getters for test validation
    function storedValue() external view returns (uint256) {
        return _storedValue;
    }

    function checkPassed() external view returns (bool) {
        return _checkPassed;
    }

    // Allow receiving ETH
    receive() external payable {}
}

/**
 * @notice Contract for testing multiple replacements in a single call
 */
contract MultipleReplacementTarget {
    uint256 public value1;
    uint256 public value2;

    /**
     * @notice Set two separate values
     * @param _value1 First value to store
     * @param _value2 Second value to store
     */
    function setValues(uint256 _value1, uint256 _value2) external {
        value1 = _value1;
        value2 = _value2;
    }
}
