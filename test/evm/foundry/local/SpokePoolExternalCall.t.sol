// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";
import { MockSpokePool } from "../../../../contracts/test/MockSpokePool.sol";
import { WETH9 } from "../../../../contracts/external/WETH9.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { SpokePoolInterface } from "../../../../contracts/interfaces/SpokePoolInterface.sol";
import { V3SpokePoolInterface } from "../../../../contracts/interfaces/V3SpokePoolInterface.sol";

contract SpokePoolExternalCallTest is Test {
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

    function testExecuteExternalCall_ExternalCall() public {
        // Test calls approve on WETH to test external call
        // Initial allowance should be 0
        assertEq(mockWETH.allowance(address(spokePool), anon), 0);

        // Encode approve(address,uint256) call to WETH
        uint256 approvalAmount = 100;
        bytes memory data = abi.encodeWithSignature("approve(address,uint256)", anon, approvalAmount);
        bytes memory message = abi.encode(address(mockWETH), data);

        // Execute external call as owner
        vm.prank(owner);
        spokePool.executeExternalCall(message);

        // Verify approval was set
        assertEq(mockWETH.allowance(address(spokePool), anon), approvalAmount);
    }

    function testExecuteExternalCall_ReturnsDataFromExternalCall() public {
        // Test that return data is captured from external calls
        // approve() returns a bool, so we should get that back

        uint256 approvalAmount = 100;
        bytes memory data = abi.encodeWithSignature("approve(address,uint256)", anon, approvalAmount);
        bytes memory message = abi.encode(address(mockWETH), data);

        vm.prank(owner);
        bytes memory returnData = spokePool.executeExternalCall(message);

        // Decode the bool return value
        bool approveSuccess = abi.decode(returnData, (bool));
        assertTrue(approveSuccess);
    }

    // =============== FAILURE CASES ===============

    function testExecuteExternalCall_RevertsWhenNotAdmin() public {
        // Try to execute external call as non-owner
        bytes memory data = abi.encodeWithSignature("approve(address,uint256)", anon, 100);
        bytes memory message = abi.encode(address(mockWETH), data);

        vm.prank(anon);
        vm.expectRevert();
        spokePool.executeExternalCall(message);
    }

    function testExecuteExternalCall_RevertsOnZeroAddress() public {
        vm.prank(owner);

        // Target is zero address, should revert
        bytes memory data = abi.encodeWithSignature("approve(address,uint256)", anon, 100);
        bytes memory message = abi.encode(address(0), data);

        vm.expectRevert(SpokePoolInterface.ZeroAddressTarget.selector);
        spokePool.executeExternalCall(message);
    }

    function testExecuteExternalCall_RevertsOnMessageTooShort() public {
        vm.prank(owner);

        // Message with less than 4 bytes (no valid selector)
        bytes memory data = hex"1234"; // Only 2 bytes
        bytes memory message = abi.encode(address(spokePool), data);

        vm.expectRevert(SpokePoolInterface.MessageTooShort.selector);
        spokePool.executeExternalCall(message);
    }

    function testExecuteExternalCall_RevertsOnMessageEmpty() public {
        vm.prank(owner);

        bytes memory data = hex"";
        bytes memory message = abi.encode(address(spokePool), data);

        vm.expectRevert(SpokePoolInterface.MessageTooShort.selector);
        spokePool.executeExternalCall(message);
    }

    function testExecuteExternalCall_RevertsOnExternalCallNonExistentFunction() public {
        vm.prank(owner);

        // Try to call a non-existent function
        bytes memory data = abi.encodeWithSignature("nonExistentFunction()");
        bytes memory message = abi.encode(address(spokePool), data);

        vm.expectRevert(SpokePoolInterface.ExternalCallExecutionFailed.selector);
        spokePool.executeExternalCall(message);
    }

    function testExecuteExternalCall_RevertsOnExternalCallFailure() public {
        // Verify spokePool has no WETH balance
        assertEq(mockWETH.balanceOf(address(spokePool)), 0);

        // Try to transfer WETH that spokePool doesn't have - should revert
        uint256 transferAmount = 100;
        bytes memory data = abi.encodeWithSignature("transfer(address,uint256)", anon, transferAmount);
        bytes memory message = abi.encode(address(mockWETH), data);

        vm.prank(owner);
        vm.expectRevert(SpokePoolInterface.ExternalCallExecutionFailed.selector);
        spokePool.executeExternalCall(message);
    }

    function testExecuteExternalCall_RevertsOnInvalidFunctionSelector() public {
        vm.prank(owner);

        // 4 bytes but invalid selector
        bytes memory data = hex"12345678"; // 4 bytes but doesn't match any function
        bytes memory message = abi.encode(address(spokePool), data);

        vm.expectRevert(SpokePoolInterface.ExternalCallExecutionFailed.selector);
        spokePool.executeExternalCall(message);
    }

    function testExecuteExternalCall_RevertsOnReentrancy() public {
        // Test that executeExternalCall cannot be used to reenter another nonReentrant function
        // Create a fillRelay call (which has nonReentrant modifier)
        V3SpokePoolInterface.V3RelayData memory relayData = V3SpokePoolInterface.V3RelayData({
            depositor: bytes32(uint256(uint160(anon))),
            recipient: bytes32(uint256(uint160(anon))),
            exclusiveRelayer: bytes32(0),
            inputToken: bytes32(uint256(uint160(address(mockWETH)))),
            outputToken: bytes32(uint256(uint160(address(mockWETH)))),
            inputAmount: 100,
            outputAmount: 100,
            originChainId: 1,
            depositId: 1,
            fillDeadline: uint32(block.timestamp + 1000),
            exclusivityDeadline: 0,
            message: ""
        });

        bytes memory fillRelayData = abi.encodeWithSignature(
            "fillRelay((bytes32,bytes32,bytes32,bytes32,bytes32,uint256,uint256,uint256,uint32,uint32,uint32,bytes),uint256,bytes32)",
            relayData,
            block.chainid,
            bytes32(uint256(uint160(anon)))
        );
        bytes memory message = abi.encode(address(spokePool), fillRelayData);

        // This should revert because fillRelay has nonReentrant modifier
        // and we're already inside executeExternalCall which also has nonReentrant
        vm.prank(owner);
        vm.expectRevert(); // Should revert with ReentrancyGuard error
        spokePool.executeExternalCall(message);
    }
}
