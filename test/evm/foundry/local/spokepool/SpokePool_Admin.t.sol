// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";
import { MockSpokePool } from "../../../../../contracts/test/MockSpokePool.sol";
import { WETH9 } from "../../../../../contracts/external/WETH9.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { SpokePoolUtils } from "../../utils/SpokePoolUtils.sol";

/**
 * @title SpokePool_AdminTest
 * @notice Tests for SpokePool admin functions.
 * @dev Migrated from test/evm/hardhat/SpokePool.Admin.ts
 */
contract SpokePool_AdminTest is Test {
    MockSpokePool public spokePool;
    WETH9 public weth;

    address public owner;
    address public crossDomainAdmin;
    address public hubPool;

    // Mock merkle roots for testing
    bytes32 public mockRelayerRefundRoot;
    bytes32 public mockSlowRelayRoot;

    event PausedDeposits(bool isPaused);
    event PausedFills(bool isPaused);
    event EmergencyDeletedRootBundle(uint256 indexed rootBundleId);

    function setUp() public {
        owner = makeAddr("owner");
        crossDomainAdmin = makeAddr("crossDomainAdmin");
        hubPool = makeAddr("hubPool");

        // Create mock roots
        mockRelayerRefundRoot = SpokePoolUtils.createRandomBytes32(1);
        mockSlowRelayRoot = SpokePoolUtils.createRandomBytes32(2);

        // Deploy WETH
        weth = new WETH9();

        // Deploy SpokePool as owner
        vm.startPrank(owner);
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(new MockSpokePool(address(weth))),
            abi.encodeCall(MockSpokePool.initialize, (0, crossDomainAdmin, hubPool))
        );
        spokePool = MockSpokePool(payable(proxy));
        spokePool.setChainId(SpokePoolUtils.DESTINATION_CHAIN_ID);
        vm.stopPrank();
    }

    /**
     * @notice Test that initial deposit ID can be set during proxy deployment.
     */
    function testSetInitialDepositId() public {
        uint32 initialDepositId = 1;

        vm.prank(owner);
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(new MockSpokePool(address(weth))),
            abi.encodeCall(MockSpokePool.initialize, (initialDepositId, owner, hubPool))
        );
        MockSpokePool newSpokePool = MockSpokePool(payable(proxy));

        assertEq(newSpokePool.numberOfDeposits(), initialDepositId);
    }

    /**
     * @notice Test pausing and unpausing deposits.
     */
    function testPauseDeposits() public {
        // Initially deposits should not be paused
        assertEq(spokePool.pausedDeposits(), false);

        // Pause deposits
        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit PausedDeposits(true);
        spokePool.pauseDeposits(true);

        assertEq(spokePool.pausedDeposits(), true);

        // Unpause deposits
        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit PausedDeposits(false);
        spokePool.pauseDeposits(false);

        assertEq(spokePool.pausedDeposits(), false);
    }

    /**
     * @notice Test pausing and unpausing fills.
     */
    function testPauseFills() public {
        // Initially fills should not be paused
        assertEq(spokePool.pausedFills(), false);

        // Pause fills
        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit PausedFills(true);
        spokePool.pauseFills(true);

        assertEq(spokePool.pausedFills(), true);

        // Unpause fills
        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit PausedFills(false);
        spokePool.pauseFills(false);

        assertEq(spokePool.pausedFills(), false);
    }

    /**
     * @notice Test emergency deletion of root bundles.
     */
    function testEmergencyDeleteRootBundle() public {
        // First relay a root bundle
        vm.prank(owner);
        spokePool.relayRootBundle(mockRelayerRefundRoot, mockSlowRelayRoot);

        // Verify the root bundle was stored
        (bytes32 storedSlowRelayRoot, bytes32 storedRelayerRefundRoot) = spokePool.rootBundles(0);
        assertEq(storedSlowRelayRoot, mockSlowRelayRoot);
        assertEq(storedRelayerRefundRoot, mockRelayerRefundRoot);

        // Emergency delete the root bundle
        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit EmergencyDeletedRootBundle(0);
        spokePool.emergencyDeleteRootBundle(0);

        // Verify the root bundle was deleted (both roots should be zero)
        (storedSlowRelayRoot, storedRelayerRefundRoot) = spokePool.rootBundles(0);
        assertEq(storedSlowRelayRoot, bytes32(0));
        assertEq(storedRelayerRefundRoot, bytes32(0));
    }

    /**
     * @notice Test that only owner can pause deposits.
     */
    function testPauseDepositsOnlyOwner() public {
        address nonOwner = makeAddr("nonOwner");

        vm.prank(nonOwner);
        vm.expectRevert("Ownable: caller is not the owner");
        spokePool.pauseDeposits(true);
    }

    /**
     * @notice Test that only owner can pause fills.
     */
    function testPauseFillsOnlyOwner() public {
        address nonOwner = makeAddr("nonOwner");

        vm.prank(nonOwner);
        vm.expectRevert("Ownable: caller is not the owner");
        spokePool.pauseFills(true);
    }

    /**
     * @notice Test that only owner can emergency delete root bundles.
     */
    function testEmergencyDeleteRootBundleOnlyOwner() public {
        // First relay a root bundle as owner
        vm.prank(owner);
        spokePool.relayRootBundle(mockRelayerRefundRoot, mockSlowRelayRoot);

        address nonOwner = makeAddr("nonOwner");

        vm.prank(nonOwner);
        vm.expectRevert("Ownable: caller is not the owner");
        spokePool.emergencyDeleteRootBundle(0);
    }
}
