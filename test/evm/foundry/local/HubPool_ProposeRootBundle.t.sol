// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";
import { HubPoolTestBase } from "../utils/HubPoolTestBase.sol";
import { HubPool } from "../../../../contracts/HubPool.sol";

/**
 * @title HubPool_ProposeRootBundleTest
 * @notice Foundry tests for HubPool root bundle proposal, ported from Hardhat tests.
 */
contract HubPool_ProposeRootBundleTest is HubPoolTestBase {
    // ============ Test Infrastructure ============

    address owner;
    address dataWorker;

    // ============ Constants ============

    uint256[] mockBundleEvaluationBlockNumbers;
    uint8 constant MOCK_POOL_REBALANCE_LEAF_COUNT = 5;
    bytes32 mockPoolRebalanceRoot;
    bytes32 mockRelayerRefundRoot;
    bytes32 mockSlowRelayRoot;

    // ============ Setup ============

    function setUp() public {
        // Create base fixture (deploys HubPool, WETH, tokens, UMA mocks)
        createHubPoolFixture();

        // Create test accounts
        owner = address(this); // Test contract is owner
        dataWorker = makeAddr("dataWorker");

        // Set up mock bundle data
        mockBundleEvaluationBlockNumbers = new uint256[](3);
        mockBundleEvaluationBlockNumbers[0] = 1;
        mockBundleEvaluationBlockNumbers[1] = 2;
        mockBundleEvaluationBlockNumbers[2] = 3;

        mockPoolRebalanceRoot = keccak256("poolRebalanceRoot");
        mockRelayerRefundRoot = keccak256("relayerRefundRoot");
        mockSlowRelayRoot = keccak256("slowRelayRoot");

        // Seed dataWorker with WETH for totalBond (bondAmount + finalFee)
        uint256 totalBond = BOND_AMOUNT + FINAL_FEE;
        vm.deal(dataWorker, totalBond);
        vm.prank(dataWorker);
        fixture.weth.deposit{ value: totalBond }();
    }

    // ============ Tests ============

    function test_ProposalOfRootBundleCorrectlyStoresDataEmitsEventsAndPullsTheBond() public {
        uint256 totalBond = BOND_AMOUNT + FINAL_FEE;
        uint32 expectedChallengePeriodEndTimestamp = uint32(block.timestamp + REFUND_PROPOSAL_LIVENESS);

        // Approve bond for HubPool
        vm.prank(dataWorker);
        fixture.weth.approve(address(fixture.hubPool), totalBond);

        uint256 dataWorkerWethBalanceBefore = fixture.weth.balanceOf(dataWorker);

        // Propose root bundle
        vm.expectEmit(true, true, true, true);
        emit HubPool.ProposeRootBundle(
            expectedChallengePeriodEndTimestamp,
            MOCK_POOL_REBALANCE_LEAF_COUNT,
            mockBundleEvaluationBlockNumbers,
            mockPoolRebalanceRoot,
            mockRelayerRefundRoot,
            mockSlowRelayRoot,
            dataWorker
        );
        vm.prank(dataWorker);
        fixture.hubPool.proposeRootBundle(
            mockBundleEvaluationBlockNumbers,
            MOCK_POOL_REBALANCE_LEAF_COUNT,
            mockPoolRebalanceRoot,
            mockRelayerRefundRoot,
            mockSlowRelayRoot
        );

        // Balances of the hubPool should have incremented by the bond and the dataWorker should have decremented by the bond.
        assertEq(fixture.weth.balanceOf(address(fixture.hubPool)), totalBond);
        assertEq(fixture.weth.balanceOf(dataWorker), dataWorkerWethBalanceBefore - totalBond);

        // Check root bundle proposal data
        (
            bytes32 poolRebalanceRoot,
            bytes32 relayerRefundRoot,
            bytes32 slowRelayRoot,
            uint256 claimedBitMap,
            address proposer,
            uint8 unclaimedPoolRebalanceLeafCount,
            uint32 challengePeriodEndTimestamp
        ) = fixture.hubPool.rootBundleProposal();

        assertEq(challengePeriodEndTimestamp, expectedChallengePeriodEndTimestamp);
        assertEq(unclaimedPoolRebalanceLeafCount, MOCK_POOL_REBALANCE_LEAF_COUNT);
        assertEq(poolRebalanceRoot, mockPoolRebalanceRoot);
        assertEq(relayerRefundRoot, mockRelayerRefundRoot);
        assertEq(slowRelayRoot, mockSlowRelayRoot);
        assertEq(claimedBitMap, 0); // no claims yet so everything should be marked at 0.
        assertEq(proposer, dataWorker);

        // Can not re-initialize if the previous bundle has unclaimed leaves.
        // Need to re-approve since first proposal consumed the approval
        vm.prank(dataWorker);
        fixture.weth.approve(address(fixture.hubPool), totalBond);

        // Seed dataWorker with more WETH for second proposal attempt
        vm.deal(dataWorker, totalBond);
        vm.prank(dataWorker);
        fixture.weth.deposit{ value: totalBond }();

        vm.prank(dataWorker);
        vm.expectRevert("Proposal has unclaimed leaves");
        fixture.hubPool.proposeRootBundle(
            mockBundleEvaluationBlockNumbers,
            MOCK_POOL_REBALANCE_LEAF_COUNT,
            mockPoolRebalanceRoot,
            mockRelayerRefundRoot,
            mockSlowRelayRoot
        );
    }

    function test_CannotProposeWhilePaused() public {
        uint256 totalBond = BOND_AMOUNT + FINAL_FEE;

        // Seed owner with WETH for bond
        vm.deal(owner, totalBond);
        fixture.weth.deposit{ value: totalBond }();
        fixture.weth.approve(address(fixture.hubPool), totalBond);

        // Pause the contract
        fixture.hubPool.setPaused(true);

        // Try to propose - should revert
        uint256[] memory blockNumbers = new uint256[](3);
        blockNumbers[0] = 1;
        blockNumbers[1] = 2;
        blockNumbers[2] = 3;
        bytes32 mockTreeRoot = keccak256("mockTreeRoot");

        vm.expectRevert("Contract is paused");
        fixture.hubPool.proposeRootBundle(blockNumbers, 5, mockTreeRoot, mockTreeRoot, mockSlowRelayRoot);
    }
}
