// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { HubPoolTestBase, MockStore } from "../utils/HubPoolTestBase.sol";

import { HubPool } from "../../../../contracts/HubPool.sol";
import { IERC20 } from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";
import { SkinnyOptimisticOracleInterface } from "../../../../contracts/external/uma/core/contracts/optimistic-oracle-v2/interfaces/SkinnyOptimisticOracleInterface.sol";

/**
 * @title HubPool_DisputeRootBundleTest
 * @notice Foundry tests for HubPool.disputeRootBundle.
 */
contract HubPool_DisputeRootBundleTest is HubPoolTestBase {
    // ============ Test Infrastructure ============

    address dataWorker;
    address liquidityProvider;

    // ============ Setup ============

    function setUp() public {
        createHubPoolFixture();

        dataWorker = makeAddr("dataWorker");
        liquidityProvider = makeAddr("liquidityProvider");

        // Fund data worker with WETH for bonds
        seedUserWithWeth(dataWorker, TOTAL_BOND * 2);
        vm.prank(dataWorker);
        fixture.weth.approve(address(fixture.hubPool), type(uint256).max);

        // Enable token for LP (as owner, matching Hardhat test)
        fixture.hubPool.enableL1TokenForLiquidityProvision(address(fixture.weth));

        // Fund liquidity provider and add liquidity (matching Hardhat test structure)
        seedUserWithWeth(liquidityProvider, AMOUNT_TO_LP);
        vm.startPrank(liquidityProvider);
        fixture.weth.approve(address(fixture.hubPool), AMOUNT_TO_LP);
        fixture.hubPool.addLiquidity(address(fixture.weth), AMOUNT_TO_LP);
        vm.stopPrank();
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

        // dataWorker already has approval to HubPool from setUp()
        vm.prank(dataWorker);
        fixture.hubPool.disputeRootBundle();

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

        // Verify optimistic oracle was called correctly
        // RequestId is computed as keccak256(abi.encode(requester, identifier, timestamp, ancillaryData))
        uint32 disputeTimestamp = uint32(block.timestamp);
        bytes memory ancillaryData = "";
        bytes32 requestId = keccak256(
            abi.encode(address(fixture.hubPool), DEFAULT_IDENTIFIER, disputeTimestamp, ancillaryData)
        );

        // Verify request exists in optimistic oracle
        // Public mapping getter returns tuple of all struct fields
        (address ooProposer, address disputer, , , int256 proposedPrice, , , , , uint256 bond, ) = fixture
            .optimisticOracle
            .requests(requestId);

        assertTrue(ooProposer != address(0), "Request should exist in optimistic oracle");
        assertEq(proposedPrice, int256(1e18), "Proposed price should be 1e18 (True)");
        assertEq(bond, TOTAL_BOND - FINAL_FEE, "Bond should be TOTAL_BOND - FINAL_FEE");
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
        // Set final fee equal to TOTAL_BOND (bond + finalFee)
        fixture.store.setFinalFee(address(fixture.weth), MockStore.FinalFee({ rawValue: TOTAL_BOND }));

        _proposeRootBundle();

        // Record balances before dispute
        uint256 dataWorkerBalanceBefore = fixture.weth.balanceOf(dataWorker);
        uint256 hubPoolBalanceBefore = fixture.weth.balanceOf(address(fixture.hubPool));

        vm.prank(dataWorker);
        fixture.hubPool.disputeRootBundle();

        // When finalFee >= TOTAL_BOND, the dispute is cancelled and proposer's bond is returned
        // The disputer doesn't need to pay anything
        uint256 dataWorkerBalanceAfter = fixture.weth.balanceOf(dataWorker);
        uint256 hubPoolBalanceAfter = fixture.weth.balanceOf(address(fixture.hubPool));

        // Proposer should get their bond back
        assertEq(
            dataWorkerBalanceAfter,
            dataWorkerBalanceBefore + TOTAL_BOND,
            "Proposer should receive bond back on cancellation"
        );
        assertEq(hubPoolBalanceAfter, hubPoolBalanceBefore - TOTAL_BOND, "HubPool should release the bond");

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

    function test_DisputeRootBundle_WorksWithDecreasedFinalFee() public {
        _proposeRootBundle();

        // Decrease final fee to half
        uint256 newFinalFee = FINAL_FEE / 2;
        uint256 newBond = TOTAL_BOND - newFinalFee;
        fixture.store.setFinalFee(address(fixture.weth), MockStore.FinalFee({ rawValue: newFinalFee }));

        // Record balances before dispute
        uint256 dataWorkerBalanceBefore = fixture.weth.balanceOf(dataWorker);
        uint256 hubPoolBalanceBefore = fixture.weth.balanceOf(address(fixture.hubPool));
        uint256 optimisticOracleBalanceBefore = fixture.weth.balanceOf(address(fixture.optimisticOracle));
        uint256 storeBalanceBefore = fixture.weth.balanceOf(address(fixture.store));

        // dataWorker already has approval to HubPool from setUp()
        vm.prank(dataWorker);
        fixture.hubPool.disputeRootBundle();

        // Verify token balance changes match expected values
        // dataWorker: -TOTAL_BOND (pays the bond)
        // hubPool: -TOTAL_BOND (releases the proposer's bond)
        // optimisticOracle: +TOTAL_BOND + newBond/2 (receives bond + half of new bond)
        // store: +newFinalFee + newBond/2 (receives final fee + half of new bond)
        uint256 dataWorkerBalanceAfter = fixture.weth.balanceOf(dataWorker);
        uint256 hubPoolBalanceAfter = fixture.weth.balanceOf(address(fixture.hubPool));
        uint256 optimisticOracleBalanceAfter = fixture.weth.balanceOf(address(fixture.optimisticOracle));
        uint256 storeBalanceAfter = fixture.weth.balanceOf(address(fixture.store));

        assertEq(dataWorkerBalanceAfter, dataWorkerBalanceBefore - TOTAL_BOND, "dataWorker should pay TOTAL_BOND");
        assertEq(hubPoolBalanceAfter, hubPoolBalanceBefore - TOTAL_BOND, "hubPool should release TOTAL_BOND");
        assertEq(
            optimisticOracleBalanceAfter,
            optimisticOracleBalanceBefore + TOTAL_BOND + newBond / 2,
            "optimisticOracle should receive TOTAL_BOND + newBond/2"
        );
        assertEq(
            storeBalanceAfter,
            storeBalanceBefore + newFinalFee + newBond / 2,
            "store should receive newFinalFee + newBond/2"
        );

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

    function test_DisputeRootBundle_AnyoneCanDispute() public {
        _proposeRootBundle();

        address randomDisputer = makeAddr("randomDisputer");

        // Fund disputer with WETH
        vm.deal(randomDisputer, 10 ether);
        vm.startPrank(randomDisputer);
        fixture.weth.deposit{ value: TOTAL_BOND }();
        fixture.weth.approve(address(fixture.hubPool), type(uint256).max);
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

    function test_DisputeRootBundle_RevertsIfNoProposal() public {
        // No proposal has been made
        // Attempting to dispute should fail because challengePeriodEndTimestamp is 0
        // and currentTime > 0
        vm.prank(dataWorker);
        vm.expectRevert("Request passed liveness");
        fixture.hubPool.disputeRootBundle();
    }
}
