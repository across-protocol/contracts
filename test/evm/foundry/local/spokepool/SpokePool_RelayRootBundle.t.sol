// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";
import { MockSpokePool } from "../../../../../contracts/test/MockSpokePool.sol";
import { WETH9 } from "../../../../../contracts/external/WETH9.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { SpokePoolUtils } from "../../utils/SpokePoolUtils.sol";

/**
 * @title SpokePool_RelayRootBundleTest
 * @notice Tests for SpokePool relayRootBundle functionality.
 * @dev Migrated from test/evm/hardhat/SpokePool.RelayRootBundle.ts
 */
contract SpokePool_RelayRootBundleTest is Test {
    MockSpokePool public spokePool;
    WETH9 public weth;

    address public owner;
    address public dataWorker;

    // Mock merkle roots for testing
    bytes32 public mockRelayerRefundRoot;
    bytes32 public mockSlowRelayRoot;

    event RelayedRootBundle(
        uint32 indexed rootBundleId,
        bytes32 indexed relayerRefundRoot,
        bytes32 indexed slowRelayRoot
    );

    function setUp() public {
        owner = makeAddr("owner");
        dataWorker = makeAddr("dataWorker");

        // Create mock roots
        mockRelayerRefundRoot = SpokePoolUtils.createRandomBytes32(1);
        mockSlowRelayRoot = SpokePoolUtils.createRandomBytes32(2);

        // Deploy WETH
        weth = new WETH9();

        // Deploy SpokePool as owner
        vm.startPrank(owner);
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(new MockSpokePool(address(weth))),
            abi.encodeCall(MockSpokePool.initialize, (0, owner, owner))
        );
        spokePool = MockSpokePool(payable(proxy));
        spokePool.setChainId(SpokePoolUtils.DESTINATION_CHAIN_ID);
        vm.stopPrank();
    }

    /**
     * @notice Test that relaying a root bundle stores the roots and emits an event.
     */
    function testRelayRootBundle() public {
        // Relay root bundle and verify event
        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit RelayedRootBundle(0, mockRelayerRefundRoot, mockSlowRelayRoot);
        spokePool.relayRootBundle(mockRelayerRefundRoot, mockSlowRelayRoot);

        // Verify the roots were stored correctly
        (bytes32 storedSlowRelayRoot, bytes32 storedRelayerRefundRoot) = spokePool.rootBundles(0);
        assertEq(storedSlowRelayRoot, mockSlowRelayRoot);
        assertEq(storedRelayerRefundRoot, mockRelayerRefundRoot);
    }

    /**
     * @notice Test that multiple root bundles can be relayed with incrementing IDs.
     */
    function testRelayMultipleRootBundles() public {
        bytes32 secondRelayerRefundRoot = SpokePoolUtils.createRandomBytes32(3);
        bytes32 secondSlowRelayRoot = SpokePoolUtils.createRandomBytes32(4);

        // Relay first root bundle
        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit RelayedRootBundle(0, mockRelayerRefundRoot, mockSlowRelayRoot);
        spokePool.relayRootBundle(mockRelayerRefundRoot, mockSlowRelayRoot);

        // Relay second root bundle
        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit RelayedRootBundle(1, secondRelayerRefundRoot, secondSlowRelayRoot);
        spokePool.relayRootBundle(secondRelayerRefundRoot, secondSlowRelayRoot);

        // Verify both root bundles
        (bytes32 storedSlowRelayRoot0, bytes32 storedRelayerRefundRoot0) = spokePool.rootBundles(0);
        assertEq(storedSlowRelayRoot0, mockSlowRelayRoot);
        assertEq(storedRelayerRefundRoot0, mockRelayerRefundRoot);

        (bytes32 storedSlowRelayRoot1, bytes32 storedRelayerRefundRoot1) = spokePool.rootBundles(1);
        assertEq(storedSlowRelayRoot1, secondSlowRelayRoot);
        assertEq(storedRelayerRefundRoot1, secondRelayerRefundRoot);
    }

    /**
     * @notice Test that only admin can relay root bundles.
     */
    function testRelayRootBundleOnlyAdmin() public {
        address nonOwner = makeAddr("nonOwner");

        vm.prank(nonOwner);
        vm.expectRevert("Ownable: caller is not the owner");
        spokePool.relayRootBundle(mockRelayerRefundRoot, mockSlowRelayRoot);
    }
}
