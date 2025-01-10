// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";
import { MockSpokePool } from "../../../../contracts/test/MockSpokePool.sol";
import { WETH9 } from "../../../../contracts/external/WETH9.sol";
import { AddressToBytes32 } from "../../../../contracts/libraries/AddressConverters.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

// Deprecated interface used to show that we can still call deposit() on the spoke, which should route internally to the
// colliding function interface selector on depositDeprecated_5947912356 enabling legacy deposits to still work without
// breaking interface changes.
interface DeprecatedSpokePoolInterface {
    function deposit(
        address recipient,
        address originToken,
        uint256 amount,
        uint256 destinationChainId,
        int64 relayerFeePct,
        uint32 quoteTimestamp,
        bytes memory message,
        uint256
    ) external payable;
}

contract SpokePoolOverloadedDeprecatedMethodsTest is Test {
    using AddressToBytes32 for address;

    MockSpokePool spokePool;
    WETH9 mockWETH;

    address depositor;
    address owner;

    uint256 destinationChainId = 10;
    uint256 depositAmount = 0.5 * (10**18);

    function setUp() public {
        mockWETH = new WETH9();

        depositor = vm.addr(1);
        owner = vm.addr(2);

        vm.startPrank(owner);
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(new MockSpokePool(address(mockWETH))),
            abi.encodeCall(MockSpokePool.initialize, (0, owner, address(420)))
        );
        spokePool = MockSpokePool(payable(proxy));

        spokePool.setEnableRoute(address(mockWETH), destinationChainId, true);

        vm.stopPrank();

        deal(depositor, depositAmount * 2);

        vm.startPrank(depositor);
        mockWETH.deposit{ value: depositAmount }();
        mockWETH.approve(address(spokePool), depositAmount);
        vm.stopPrank();

        // Assert that the spokePool balance is zero at the start
        assertEq(mockWETH.balanceOf(address(spokePool)), 0, "SpokePool balance should be zero at setup");
    }

    function testDeprecatedDeposit() public {
        // Here, we are calling the deprecated deposit method, as defined in the deprecated interface. This should, in
        // theory, collide with the function selector depositDeprecated_5947912356, thereby calling the legacy deposit
        // method on the spoke pool, while using the old old deposit function signature.
        vm.startPrank(depositor);

        DeprecatedSpokePoolInterface(address(spokePool)).deposit(
            depositor, // recipient
            address(mockWETH), // originToken
            depositAmount, // amount
            destinationChainId, // destinationChainId
            0, // relayerFeePct
            uint32(block.timestamp), // quoteTimestamp
            bytes(""), // message
            0 // maxCount
        );

        assertEq(mockWETH.balanceOf(address(spokePool)), depositAmount, "SpokePool balance should increase");

        // Test depositing native ETH directly
        DeprecatedSpokePoolInterface(address(spokePool)).deposit{ value: depositAmount }(
            depositor, // recipient
            address(mockWETH), // originToken - still WETH address for native deposits
            depositAmount, // amount
            destinationChainId, // destinationChainId
            0, // relayerFeePct
            uint32(block.timestamp), // quoteTimestamp
            bytes(""), // message
            0 // maxCount
        );
        vm.stopPrank();

        assertEq(mockWETH.balanceOf(address(spokePool)), depositAmount * 2, "SpokePool balance should increase");
    }

    function testBytes32Deposit() public {
        vm.prank(depositor);

        // Show the bytes32 variant of the new deposit method works.
        spokePool.deposit(
            address(depositor).toBytes32(), // depositor
            address(depositor).toBytes32(), // recipient
            address(mockWETH).toBytes32(), // inputToken
            address(mockWETH).toBytes32(), // outputToken
            depositAmount, // inputAmount
            0, // outputAmount
            destinationChainId, // destinationChainId
            bytes32(0), // exclusiveRelayer
            uint32(block.timestamp), // quoteTimestamp
            uint32(block.timestamp + 1 hours), // fillDeadline
            0, // exclusivityParameter
            bytes("") // message
        );

        assertEq(mockWETH.balanceOf(address(spokePool)), depositAmount, "SpokePool balance should increase");
    }

    function testAddressDeposit() public {
        // Show the address variant of the new deposit method works.
        vm.prank(depositor);
        spokePool.depositV3(
            depositor, // depositor
            depositor, // recipient
            address(mockWETH), // inputToken
            address(mockWETH), // outputToken
            depositAmount, // inputAmount
            0, // outputAmount
            destinationChainId, // destinationChainId
            address(0), // exclusiveRelayer
            uint32(block.timestamp), // quoteTimestamp
            uint32(block.timestamp + 1 hours), // fillDeadline
            0, // exclusivityParameter
            bytes("") // message
        );

        assertEq(mockWETH.balanceOf(address(spokePool)), depositAmount, "SpokePool balance should increase");
    }
}
