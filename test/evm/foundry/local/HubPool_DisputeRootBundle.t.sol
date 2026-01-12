// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { HubPoolTestBase, MockStore, MockOptimisticOracle } from "../utils/HubPoolTestBase.sol";

import { HubPool } from "../../../../contracts/HubPool.sol";
import { OracleInterfaces } from "../../../../contracts/external/uma/core/contracts/data-verification-mechanism/implementation/Constants.sol";
import { IERC20 } from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";

/**
 * @title HubPool_DisputeRootBundleTest
 * @notice Foundry tests for HubPool.disputeRootBundle, ported from Hardhat tests.
 * @dev Some tests that require full UMA ecosystem integration are simplified or skipped.
 */
contract HubPool_DisputeRootBundleTest is HubPoolTestBase {
    // ============ Test Infrastructure ============

    MockOptimisticOracle mockOptimisticOracle;
    MockStore mockStore;
    address dataWorker;

    // ============ Constants ============
    // Note: REFUND_PROPOSAL_LIVENESS, BOND_AMOUNT, FINAL_FEE, DEFAULT_IDENTIFIER
    // are inherited from HubPoolTestBase

    uint256 constant AMOUNT_TO_LP = 1000 ether;

    bytes32 constant MOCK_POOL_REBALANCE_ROOT = bytes32(uint256(0xabc));
    bytes32 constant MOCK_RELAYER_REFUND_ROOT = bytes32(uint256(0x1234));
    bytes32 constant MOCK_SLOW_RELAY_ROOT = bytes32(uint256(0x5678));

    // ============ Setup ============

    function setUp() public {
        createHubPoolFixture();

        dataWorker = makeAddr("dataWorker");

        // Deploy mocks with fees support
        mockStore = new MockStore();
        mockOptimisticOracle = new MockOptimisticOracle(REFUND_PROPOSAL_LIVENESS * 10);

        // Update finder to use our mocks
        fixture.finder.changeImplementationAddress(OracleInterfaces.Store, address(mockStore));
        fixture.finder.changeImplementationAddress(
            OracleInterfaces.SkinnyOptimisticOracle,
            address(mockOptimisticOracle)
        );

        // Set final fee for WETH
        mockStore.setFinalFee(address(fixture.weth), MockStore.FinalFee({ rawValue: FINAL_FEE }));

        // Note: liveness is already set by createHubPoolFixture()

        // Fund data worker with WETH for bonds
        uint256 totalBond = BOND_AMOUNT + FINAL_FEE;
        vm.deal(dataWorker, totalBond * 3); // Enough for multiple proposals/disputes
        vm.startPrank(dataWorker);
        fixture.weth.deposit{ value: totalBond * 2 }();
        fixture.weth.approve(address(fixture.hubPool), type(uint256).max);
        vm.stopPrank();

        // Add liquidity as LP - need more ETH first
        vm.deal(address(this), AMOUNT_TO_LP + 10 ether);
        fixture.hubPool.enableL1TokenForLiquidityProvision(address(fixture.weth));
        fixture.hubPool.addLiquidity{ value: AMOUNT_TO_LP }(address(fixture.weth), AMOUNT_TO_LP);
    }

    // ============ Helper Functions ============

    function _proposeRootBundle() internal {
        uint256[] memory bundleEvaluationBlockNumbers = new uint256[](3);
        bundleEvaluationBlockNumbers[0] = 1;
        bundleEvaluationBlockNumbers[1] = 2;
        bundleEvaluationBlockNumbers[2] = 3;

        vm.prank(dataWorker);
        fixture.hubPool.proposeRootBundle(
            bundleEvaluationBlockNumbers,
            5, // poolRebalanceLeafCount
            MOCK_POOL_REBALANCE_ROOT,
            MOCK_RELAYER_REFUND_ROOT,
            MOCK_SLOW_RELAY_ROOT
        );
    }

    // ============ Tests ============

    function test_DisputeRootBundle_DeletesActiveProposal() public {
        _proposeRootBundle();

        // Increment time slightly to avoid weirdness
        vm.warp(block.timestamp + 15);

        // Approve OO to spend disputer's bond
        vm.startPrank(dataWorker);
        fixture.weth.approve(address(mockOptimisticOracle), type(uint256).max);
        fixture.hubPool.disputeRootBundle();
        vm.stopPrank();

        // Verify proposal is cleared
        (
            bytes32 poolRebalanceRoot,
            bytes32 relayerRefundRoot,
            bytes32 slowRelayRoot,
            uint256 claimedBitMap,
            address proposer,
            uint8 unclaimedPoolRebalanceLeafCount,
            uint32 challengePeriodEndTimestamp
        ) = fixture.hubPool.rootBundleProposal();

        assertEq(poolRebalanceRoot, bytes32(0), "poolRebalanceRoot should be cleared");
        assertEq(relayerRefundRoot, bytes32(0), "relayerRefundRoot should be cleared");
        assertEq(slowRelayRoot, bytes32(0), "slowRelayRoot should be cleared");
        assertEq(claimedBitMap, 0, "claimedBitMap should be 0");
        assertEq(proposer, address(0), "proposer should be cleared");
        assertEq(unclaimedPoolRebalanceLeafCount, 0, "unclaimedPoolRebalanceLeafCount should be 0");
        assertEq(challengePeriodEndTimestamp, 0, "challengePeriodEndTimestamp should be 0");
    }

    function test_DisputeRootBundle_RevertsAfterLiveness() public {
        _proposeRootBundle();

        // Warp past liveness period
        vm.warp(block.timestamp + REFUND_PROPOSAL_LIVENESS + 1);

        vm.prank(dataWorker);
        vm.expectRevert("Request passed liveness");
        fixture.hubPool.disputeRootBundle();
    }

    function test_DisputeRootBundle_CancelsWhenFinalFeeEqualsBond() public {
        // Set final fee equal to totalBond (bond + finalFee)
        uint256 totalBond = BOND_AMOUNT + FINAL_FEE;
        mockStore.setFinalFee(address(fixture.weth), MockStore.FinalFee({ rawValue: totalBond }));

        _proposeRootBundle();

        // Record balances before dispute
        uint256 dataWorkerBalanceBefore = fixture.weth.balanceOf(dataWorker);
        uint256 hubPoolBalanceBefore = fixture.weth.balanceOf(address(fixture.hubPool));

        vm.prank(dataWorker);
        fixture.hubPool.disputeRootBundle();

        // When finalFee >= totalBond, the dispute is cancelled and proposer's bond is returned
        // The disputer doesn't need to pay anything
        uint256 dataWorkerBalanceAfter = fixture.weth.balanceOf(dataWorker);
        uint256 hubPoolBalanceAfter = fixture.weth.balanceOf(address(fixture.hubPool));

        // Proposer should get their bond back
        assertEq(
            dataWorkerBalanceAfter,
            dataWorkerBalanceBefore + totalBond,
            "Proposer should receive bond back on cancellation"
        );
        assertEq(hubPoolBalanceAfter, hubPoolBalanceBefore - totalBond, "HubPool should release the bond");

        // Verify proposal is cleared
        (bytes32 poolRebalanceRoot, , , , , , ) = fixture.hubPool.rootBundleProposal();
        assertEq(poolRebalanceRoot, bytes32(0), "Proposal should be cleared");
    }

    function test_DisputeRootBundle_WorksWithDecreasedFinalFee() public {
        _proposeRootBundle();

        // Decrease final fee to half
        uint256 newFinalFee = FINAL_FEE / 2;
        mockStore.setFinalFee(address(fixture.weth), MockStore.FinalFee({ rawValue: newFinalFee }));

        // Approve OO to spend disputer's bond
        vm.startPrank(dataWorker);
        fixture.weth.approve(address(mockOptimisticOracle), type(uint256).max);
        fixture.hubPool.disputeRootBundle();
        vm.stopPrank();

        // Verify proposal is cleared
        (bytes32 poolRebalanceRoot, , , , , , ) = fixture.hubPool.rootBundleProposal();
        assertEq(poolRebalanceRoot, bytes32(0), "Proposal should be cleared");
    }

    function test_DisputeRootBundle_AnyoneCanDispute() public {
        _proposeRootBundle();

        address randomDisputer = makeAddr("randomDisputer");

        // Fund disputer with WETH
        vm.deal(randomDisputer, 10 ether);
        vm.startPrank(randomDisputer);
        fixture.weth.deposit{ value: BOND_AMOUNT + FINAL_FEE }();
        fixture.weth.approve(address(fixture.hubPool), type(uint256).max);
        fixture.weth.approve(address(mockOptimisticOracle), type(uint256).max);
        fixture.hubPool.disputeRootBundle();
        vm.stopPrank();

        // Verify proposal is cleared
        (bytes32 poolRebalanceRoot, , , , , , ) = fixture.hubPool.rootBundleProposal();
        assertEq(poolRebalanceRoot, bytes32(0), "Proposal should be cleared by random disputer");
    }

    function test_DisputeRootBundle_RevertsIfNoProposal() public {
        // No proposal has been made
        // Attempting to dispute should fail because challengePeriodEndTimestamp is 0
        // and currentTime > 0
        vm.prank(dataWorker);
        vm.expectRevert("Request passed liveness");
        fixture.hubPool.disputeRootBundle();
    }
}
