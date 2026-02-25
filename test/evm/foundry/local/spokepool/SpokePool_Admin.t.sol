// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts-v4/proxy/ERC1967/ERC1967Proxy.sol";
import { MockSpokePool } from "../../../../../contracts/test/MockSpokePool.sol";
import { WETH9 } from "../../../../../contracts/external/WETH9.sol";

contract SpokePoolAdminTest is Test {
    MockSpokePool public spokePool;
    WETH9 public weth;
    address public owner;
    address public crossDomainAdmin;
    address public hubPool;

    bytes32 public mockRelayerRefundRoot;
    bytes32 public mockSlowRelayRoot;

    event PausedDeposits(bool isPaused);
    event PausedFills(bool isPaused);
    event EmergencyDeletedRootBundle(uint256 indexed rootBundleId);

    function setUp() public {
        owner = makeAddr("owner");
        crossDomainAdmin = makeAddr("crossDomainAdmin");
        hubPool = makeAddr("hubPool");

        mockRelayerRefundRoot = keccak256("mockRelayerRefundRoot");
        mockSlowRelayRoot = keccak256("mockSlowRelayRoot");

        weth = new WETH9();

        vm.startPrank(owner);
        MockSpokePool implementation = new MockSpokePool(address(weth));
        address proxy = address(
            new ERC1967Proxy(
                address(implementation),
                abi.encodeCall(MockSpokePool.initialize, (0, crossDomainAdmin, hubPool))
            )
        );
        spokePool = MockSpokePool(payable(proxy));
        vm.stopPrank();
    }

    function testCanSetInitialDepositId() public {
        vm.startPrank(owner);
        MockSpokePool implementation = new MockSpokePool(address(weth));
        address proxy = address(
            new ERC1967Proxy(
                address(implementation),
                abi.encodeCall(MockSpokePool.initialize, (1, crossDomainAdmin, hubPool))
            )
        );
        MockSpokePool newSpokePool = MockSpokePool(payable(proxy));
        vm.stopPrank();

        assertEq(newSpokePool.numberOfDeposits(), 1);
    }

    function testPauseDeposits() public {
        assertEq(spokePool.pausedDeposits(), false);

        vm.startPrank(owner);

        vm.expectEmit(true, true, true, true);
        emit PausedDeposits(true);
        spokePool.pauseDeposits(true);
        assertEq(spokePool.pausedDeposits(), true);

        vm.expectEmit(true, true, true, true);
        emit PausedDeposits(false);
        spokePool.pauseDeposits(false);
        assertEq(spokePool.pausedDeposits(), false);

        vm.stopPrank();
    }

    function testPauseFills() public {
        assertEq(spokePool.pausedFills(), false);

        vm.startPrank(owner);

        vm.expectEmit(true, true, true, true);
        emit PausedFills(true);
        spokePool.pauseFills(true);
        assertEq(spokePool.pausedFills(), true);

        vm.expectEmit(true, true, true, true);
        emit PausedFills(false);
        spokePool.pauseFills(false);
        assertEq(spokePool.pausedFills(), false);

        vm.stopPrank();
    }

    function testDeleteRootBundle() public {
        vm.startPrank(owner);
        spokePool.relayRootBundle(mockRelayerRefundRoot, mockSlowRelayRoot);

        (bytes32 slowRelayRoot, bytes32 relayerRefundRoot) = spokePool.rootBundles(0);
        assertEq(slowRelayRoot, mockSlowRelayRoot);
        assertEq(relayerRefundRoot, mockRelayerRefundRoot);

        vm.expectEmit(true, true, true, true);
        emit EmergencyDeletedRootBundle(0);
        spokePool.emergencyDeleteRootBundle(0);

        (slowRelayRoot, relayerRefundRoot) = spokePool.rootBundles(0);
        assertEq(slowRelayRoot, bytes32(0));
        assertEq(relayerRefundRoot, bytes32(0));

        vm.stopPrank();
    }
}
