// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";
import { MockSpokePool } from "../../../../../contracts/test/MockSpokePool.sol";
import { MockSpokePoolV2 } from "../../../../../contracts/test/MockSpokePoolV2.sol";
import { WETH9 } from "../../../../../contracts/external/WETH9.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { SpokePoolUtils } from "../../utils/SpokePoolUtils.sol";

/**
 * @title SpokePool_UpgradesTest
 * @notice Tests for SpokePool UUPS upgrade functionality.
 * @dev Migrated from test/evm/hardhat/SpokePool.Upgrades.ts
 */
contract SpokePool_UpgradesTest is Test {
    MockSpokePool public spokePool;
    WETH9 public weth;

    address public owner;
    address public rando;
    address public hubPool;

    event NewEvent(bool value);

    function setUp() public {
        owner = makeAddr("owner");
        rando = makeAddr("rando");
        hubPool = makeAddr("hubPool");

        // Deploy WETH
        weth = new WETH9();

        // Deploy SpokePool as owner
        vm.startPrank(owner);
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(new MockSpokePool(address(weth))),
            abi.encodeCall(MockSpokePool.initialize, (0, owner, hubPool))
        );
        spokePool = MockSpokePool(payable(proxy));
        spokePool.setChainId(SpokePoolUtils.DESTINATION_CHAIN_ID);
        vm.stopPrank();
    }

    /**
     * @notice Test that the SpokePool can be upgraded and reinitialized.
     */
    function testUpgradeWithReinitialize() public {
        // Deploy V2 implementation
        MockSpokePoolV2 spokePoolV2Implementation = new MockSpokePoolV2(makeAddr("randomWeth"));

        address newHubPool = makeAddr("newHubPool");

        // Prepare reinitialize call data
        bytes memory reinitializeData = abi.encodeCall(MockSpokePoolV2.reinitialize, (newHubPool));

        // Non-owner should not be able to upgrade
        vm.prank(rando);
        vm.expectRevert("Ownable: caller is not the owner");
        spokePool.upgradeToAndCall(address(spokePoolV2Implementation), reinitializeData);

        // Owner should be able to upgrade
        vm.prank(owner);
        spokePool.upgradeToAndCall(address(spokePoolV2Implementation), reinitializeData);

        // Cast to V2 to access new functions
        MockSpokePoolV2 spokePoolV2 = MockSpokePoolV2(payable(address(spokePool)));

        // Hub pool should be changed (withdrawalRecipient is set to hubPool in reinitialize)
        assertEq(spokePoolV2.withdrawalRecipient(), newHubPool);

        // Cannot reinitialize again
        vm.expectRevert();
        spokePoolV2.reinitialize(newHubPool);

        // Can call new V2 function
        vm.expectEmit(true, true, true, true);
        emit NewEvent(true);
        spokePoolV2.emitEvent();
    }

    /**
     * @notice Test that upgrade preserves existing state.
     */
    function testUpgradePreservesState() public {
        // Set some state on V1
        bytes32 mockRelayerRefundRoot = SpokePoolUtils.createRandomBytes32(1);
        bytes32 mockSlowRelayRoot = SpokePoolUtils.createRandomBytes32(2);

        vm.prank(owner);
        spokePool.relayRootBundle(mockRelayerRefundRoot, mockSlowRelayRoot);

        // Verify initial state
        (bytes32 storedSlowRelayRoot, bytes32 storedRelayerRefundRoot) = spokePool.rootBundles(0);
        assertEq(storedSlowRelayRoot, mockSlowRelayRoot);
        assertEq(storedRelayerRefundRoot, mockRelayerRefundRoot);

        // Deploy V2 implementation and upgrade
        MockSpokePoolV2 spokePoolV2Implementation = new MockSpokePoolV2(makeAddr("randomWeth"));
        address newHubPool = makeAddr("newHubPool");
        bytes memory reinitializeData = abi.encodeCall(MockSpokePoolV2.reinitialize, (newHubPool));

        vm.prank(owner);
        spokePool.upgradeToAndCall(address(spokePoolV2Implementation), reinitializeData);

        // State should be preserved
        MockSpokePoolV2 spokePoolV2 = MockSpokePoolV2(payable(address(spokePool)));
        (storedSlowRelayRoot, storedRelayerRefundRoot) = spokePoolV2.rootBundles(0);
        assertEq(storedSlowRelayRoot, mockSlowRelayRoot);
        assertEq(storedRelayerRefundRoot, mockRelayerRefundRoot);
    }

    /**
     * @notice Test upgrade without reinitialize call.
     */
    function testUpgradeWithoutReinitialize() public {
        // Deploy V2 implementation
        MockSpokePoolV2 spokePoolV2Implementation = new MockSpokePoolV2(makeAddr("randomWeth"));

        // Upgrade without calling reinitialize (empty calldata)
        vm.prank(owner);
        spokePool.upgradeToAndCall(address(spokePoolV2Implementation), "");

        // Cast to V2 and verify new function works
        MockSpokePoolV2 spokePoolV2 = MockSpokePoolV2(payable(address(spokePool)));

        vm.expectEmit(true, true, true, true);
        emit NewEvent(true);
        spokePoolV2.emitEvent();

        // Note: withdrawalRecipient won't be updated since reinitialize wasn't called
        // It should still be the original hubPool
        assertEq(spokePoolV2.withdrawalRecipient(), hubPool);
    }
}
