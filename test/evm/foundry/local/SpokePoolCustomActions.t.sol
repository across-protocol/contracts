// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";
import { MockSpokePool } from "../../../../contracts/test/MockSpokePool.sol";
import { WETH9 } from "../../../../contracts/external/WETH9.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { SpokePoolInterface } from "../../../../contracts/interfaces/SpokePoolInterface.sol";

contract SpokePoolCustomActionsTest is Test {
    MockSpokePool spokePool;
    WETH9 mockWETH;

    address owner;
    address anon;

    function setUp() public {
        mockWETH = new WETH9();

        owner = vm.addr(1);
        anon = vm.addr(2);

        vm.startPrank(owner);
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(new MockSpokePool(address(mockWETH))),
            abi.encodeCall(MockSpokePool.initialize, (0, owner, address(420)))
        );
        spokePool = MockSpokePool(payable(proxy));
        vm.stopPrank();
    }

    // =============== SUCCESS CASES ===============

    function testExecuteCustomActions_DelegatecallOnlyAdminFunction() public {
        // Pause deposits should be false initially
        assertFalse(spokePool.pausedDeposits());

        // Encode pauseDeposits(true) call
        bytes memory data = abi.encodeWithSignature("pauseDeposits(bool)", true);
        bytes memory message = abi.encode(address(spokePool), data);

        // Execute custom action via delegatecall as owner
        vm.prank(owner);
        spokePool.executeCustomActions(message);

        // Verify state changed (delegatecall modifies storage in the context of spokePool)
        assertTrue(spokePool.pausedDeposits());
    }

    function testExecuteCustomActions_ExternalCall() public {
        // Test calls approve on WETH to test external call
        // Initial allowance should be 0
        assertEq(mockWETH.allowance(address(spokePool), anon), 0);

        // Encode approve(address,uint256) call to WETH
        uint256 approvalAmount = 100;
        bytes memory data = abi.encodeWithSignature("approve(address,uint256)", anon, approvalAmount);
        bytes memory message = abi.encode(address(mockWETH), data);

        // Execute custom action via external call as owner
        vm.prank(owner);
        spokePool.executeCustomActions(message);

        // Verify approval was set
        assertEq(mockWETH.allowance(address(spokePool), anon), approvalAmount);
    }

    function testExecuteCustomActions_ReturnsDataFromExternalCall() public {
        // Test that return data is captured from external calls
        // approve() returns a bool, so we should get that back

        uint256 approvalAmount = 100;
        bytes memory data = abi.encodeWithSignature("approve(address,uint256)", anon, approvalAmount);
        bytes memory message = abi.encode(address(mockWETH), data);

        vm.prank(owner);
        bytes memory returnData = spokePool.executeCustomActions(message);

        // Decode the bool return value
        bool approveSuccess = abi.decode(returnData, (bool));
        assertTrue(approveSuccess);
    }

    function testExecuteCustomActions_ReturnsDataFromDelegatecall() public {
        // Test that return data is captured from delegatecalls
        // Call a view function that returns data

        bytes memory data = abi.encodeWithSignature("crossDomainAdmin()");
        bytes memory message = abi.encode(address(spokePool), data);

        vm.prank(owner);
        bytes memory returnData = spokePool.executeCustomActions(message);

        // Decode the address return value
        address returnedAdmin = abi.decode(returnData, (address));
        assertEq(returnedAdmin, spokePool.crossDomainAdmin());
        assertEq(returnedAdmin, owner);
    }

    function testExecuteCustomActions_ReturnsDataFromAllowanceCall() public {
        // Set up an allowance first
        uint256 approvalAmount = 500;
        bytes memory approveData = abi.encodeWithSignature("approve(address,uint256)", anon, approvalAmount);
        bytes memory approveMessage = abi.encode(address(mockWETH), approveData);

        vm.prank(owner);
        spokePool.executeCustomActions(approveMessage);

        // Now call allowance() which returns uint256
        bytes memory allowanceData = abi.encodeWithSignature("allowance(address,address)", address(spokePool), anon);
        bytes memory allowanceMessage = abi.encode(address(mockWETH), allowanceData);

        vm.prank(owner);
        bytes memory returnData = spokePool.executeCustomActions(allowanceMessage);

        // Decode the uint256 return value
        uint256 returnedAllowance = abi.decode(returnData, (uint256));
        assertEq(returnedAllowance, approvalAmount);
    }

    // =============== FAILURE CASES ===============

    function testExecuteCustomActions_RevertsWhenNotAdmin() public {
        // Try to call adminOnly function as non-owner
        bytes memory data = abi.encodeWithSignature("pauseDeposits(bool)", true);
        bytes memory message = abi.encode(address(spokePool), data);

        vm.prank(anon);
        vm.expectRevert();
        spokePool.executeCustomActions(message);
    }

    function testExecuteCustomActions_RevertsOnZeroAddress() public {
        vm.prank(owner);

        bytes memory data = abi.encodeWithSignature("pauseDeposits(bool)", true);
        bytes memory message = abi.encode(address(0), data);

        vm.expectRevert(SpokePoolInterface.ZeroAddressTarget.selector);
        spokePool.executeCustomActions(message);
    }

    function testExecuteCustomActions_RevertsOnMessageTooShort() public {
        vm.prank(owner);

        // Message with less than 4 bytes (no valid selector)
        bytes memory data = hex"1234"; // Only 2 bytes
        bytes memory message = abi.encode(address(spokePool), data);

        vm.expectRevert(SpokePoolInterface.MessageTooShort.selector);
        spokePool.executeCustomActions(message);
    }

    function testExecuteCustomActions_RevertsOnMessageEmpty() public {
        vm.prank(owner);

        bytes memory data = hex"";
        bytes memory message = abi.encode(address(spokePool), data);

        vm.expectRevert(SpokePoolInterface.MessageTooShort.selector);
        spokePool.executeCustomActions(message);
    }

    function testExecuteCustomActions_RevertsOnDelegatecallFailure() public {
        vm.prank(owner);

        // Try to call a non-existent function
        bytes memory data = abi.encodeWithSignature("nonExistentFunction()");
        bytes memory message = abi.encode(address(spokePool), data);

        vm.expectRevert(SpokePoolInterface.CustomActionExecutionFailed.selector);
        spokePool.executeCustomActions(message);
    }

    function testExecuteCustomActions_RevertsOnExternalCallFailure() public {
        // Verify spokePool has no WETH balance
        assertEq(mockWETH.balanceOf(address(spokePool)), 0);

        // Try to transfer WETH that spokePool doesn't have - should revert
        uint256 transferAmount = 100;
        bytes memory data = abi.encodeWithSignature("transfer(address,uint256)", anon, transferAmount);
        bytes memory message = abi.encode(address(mockWETH), data);

        vm.prank(owner);
        vm.expectRevert(SpokePoolInterface.CustomActionExecutionFailed.selector);
        spokePool.executeCustomActions(message);
    }

    function testExecuteCustomActions_RevertsOnInvalidFunctionSelector() public {
        vm.prank(owner);

        // 4 bytes but invalid selector
        bytes memory data = hex"12345678"; // 4 bytes but doesn't match any function
        bytes memory message = abi.encode(address(spokePool), data);

        vm.expectRevert(SpokePoolInterface.CustomActionExecutionFailed.selector);
        spokePool.executeCustomActions(message);
    }
}
