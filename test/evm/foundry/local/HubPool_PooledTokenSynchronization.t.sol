// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";
import { HubPoolTestBase } from "../utils/HubPoolTestBase.sol";
import { MerkleTreeUtils } from "../utils/MerkleTreeUtils.sol";
import { HubPoolInterface } from "../../../../contracts/interfaces/HubPoolInterface.sol";
import { MintableERC20 } from "../../../../contracts/test/MockERC20.sol";
import { Mock_Adapter } from "../../../../contracts/chain-adapters/Mock_Adapter.sol";

/**
 * @title HubPool_PooledTokenSynchronizationTest
 * @notice Foundry tests for HubPool pooled token synchronization, ported from Hardhat tests.
 */
contract HubPool_PooledTokenSynchronizationTest is HubPoolTestBase {
    // ============ Test Infrastructure ============

    address owner;
    address dataWorker;
    address liquidityProvider;

    MintableERC20 wethLpToken;
    Mock_Adapter mockAdapter;
    address mockSpoke;

    // ============ Constants ============

    uint256 constant AMOUNT_TO_LP = 1000 ether;
    uint256 constant REPAYMENT_CHAIN_ID = 3117;
    uint256 constant TOKENS_SEND_TO_L2 = 100 ether;
    uint256 constant REALIZED_LP_FEES = 10 ether;

    bytes32 constant MOCK_RELAYER_REFUND_ROOT = bytes32(uint256(0x1234));
    bytes32 constant MOCK_SLOW_RELAY_ROOT = bytes32(uint256(0x5678));
    bytes32 constant MOCK_TREE_ROOT = bytes32(uint256(0xabcd));

    // ============ Setup ============

    function setUp() public {
        // Create base fixture (deploys HubPool, WETH, tokens, UMA mocks)
        createHubPoolFixture();

        // Create test accounts
        owner = address(this); // Test contract is owner
        dataWorker = makeAddr("dataWorker");
        liquidityProvider = makeAddr("liquidityProvider");

        // Seed dataWorker with WETH (bondAmount + finalFee) * 10 + extra for token transfers
        // Need enough for bonds + large token transfers (500 ether for dropped tokens test)
        uint256 dataWorkerAmount = (BOND_AMOUNT + FINAL_FEE) * 10 + 600 ether;
        vm.deal(dataWorker, dataWorkerAmount);
        vm.prank(dataWorker);
        fixture.weth.deposit{ value: dataWorkerAmount }();

        // Seed liquidityProvider with WETH amountToLp * 10
        uint256 liquidityProviderAmount = AMOUNT_TO_LP * 10;
        vm.deal(liquidityProvider, liquidityProviderAmount);
        vm.prank(liquidityProvider);
        fixture.weth.deposit{ value: liquidityProviderAmount }();

        // Enable WETH for LP (creates LP token)
        fixture.hubPool.enableL1TokenForLiquidityProvision(address(fixture.weth));

        // Get LP token address
        (address wethLpTokenAddr, , , , , ) = fixture.hubPool.pooledTokens(address(fixture.weth));
        wethLpToken = MintableERC20(wethLpTokenAddr);

        // Add liquidity for WETH from liquidityProvider
        vm.prank(liquidityProvider);
        fixture.weth.approve(address(fixture.hubPool), AMOUNT_TO_LP);
        vm.prank(liquidityProvider);
        fixture.hubPool.addLiquidity(address(fixture.weth), AMOUNT_TO_LP);

        // Approve WETH for dataWorker (for bonding)
        vm.prank(dataWorker);
        fixture.weth.approve(address(fixture.hubPool), BOND_AMOUNT * 10);

        // Deploy Mock_Adapter and set up cross-chain contracts
        mockAdapter = new Mock_Adapter();
        mockSpoke = makeAddr("mockSpoke");
        fixture.hubPool.setCrossChainContracts(REPAYMENT_CHAIN_ID, address(mockAdapter), mockSpoke);
        fixture.hubPool.setPoolRebalanceRoute(REPAYMENT_CHAIN_ID, address(fixture.weth), fixture.l2Weth);
    }

    // ============ Helper Functions ============

    /**
     * @notice Constructs a single-chain tree for testing.
     * @param scalingSize Scaling factor for amounts (default 1)
     * @return leaf The pool rebalance leaf
     * @return root The merkle root
     */
    function constructSingleChainTree(
        uint256 scalingSize
    ) internal pure returns (HubPoolInterface.PoolRebalanceLeaf memory leaf, bytes32 root) {
        uint256 tokensSendToL2 = TOKENS_SEND_TO_L2 * scalingSize;
        uint256 realizedLpFees = REALIZED_LP_FEES * scalingSize;

        (leaf, root) = MerkleTreeUtils.buildSingleTokenLeaf(
            REPAYMENT_CHAIN_ID,
            address(0), // Will be set to WETH in tests
            tokensSendToL2,
            realizedLpFees
        );
    }

    /**
     * @notice Proposes a root bundle and warps past liveness period.
     */
    function _proposeRootBundle(bytes32 poolRebalanceRoot) internal {
        uint256[] memory bundleEvaluationBlockNumbers = new uint256[](1);
        bundleEvaluationBlockNumbers[0] = block.number;

        vm.prank(dataWorker);
        fixture.hubPool.proposeRootBundle(
            bundleEvaluationBlockNumbers,
            1,
            poolRebalanceRoot,
            MOCK_RELAYER_REFUND_ROOT,
            MOCK_SLOW_RELAY_ROOT
        );

        // Warp past liveness period
        vm.warp(block.timestamp + REFUND_PROPOSAL_LIVENESS + 1);
    }

    /**
     * @notice Executes a leaf from the root bundle.
     */
    function _executeLeaf(HubPoolInterface.PoolRebalanceLeaf memory leaf, bytes32[] memory proof) internal {
        vm.prank(dataWorker);
        fixture.hubPool.executeRootBundle(
            leaf.chainId,
            leaf.groupIndex,
            leaf.bundleLpFees,
            leaf.netSendAmounts,
            leaf.runningBalances,
            leaf.leafId,
            leaf.l1Tokens,
            proof
        );
    }

    /**
     * @notice Forces a state sync by calling exchangeRateCurrent.
     */
    function _forceSync(address token) internal {
        fixture.hubPool.exchangeRateCurrent(token);
    }

    // ============ Tests ============

    function test_SyncUpdatesCountersCorrectlyThroughTheLifecycleOfARelay() public {
        // Values start as expected.
        (, , , int256 utilizedReserves, uint256 liquidReserves, ) = fixture.hubPool.pooledTokens(address(fixture.weth));
        assertEq(liquidReserves, AMOUNT_TO_LP);
        assertEq(utilizedReserves, 0);
        assertEq(fixture.hubPool.exchangeRateCurrent(address(fixture.weth)), 1e18);

        // Calling sync at this point should not change the counters.
        _forceSync(address(fixture.weth));
        (, , , utilizedReserves, liquidReserves, ) = fixture.hubPool.pooledTokens(address(fixture.weth));
        assertEq(liquidReserves, AMOUNT_TO_LP);
        assertEq(utilizedReserves, 0);
        assertEq(fixture.hubPool.exchangeRateCurrent(address(fixture.weth)), 1e18);

        // Execute a relayer refund. Check counters move accordingly.
        HubPoolInterface.PoolRebalanceLeaf memory leaf;
        bytes32 root;
        (leaf, root) = constructSingleChainTree(1);
        leaf.l1Tokens[0] = address(fixture.weth);

        // Recalculate root with correct token address
        root = keccak256(abi.encode(leaf));

        _proposeRootBundle(root);

        // Bond being paid in should not impact liquid reserves.
        _forceSync(address(fixture.weth));
        (, , , utilizedReserves, liquidReserves, ) = fixture.hubPool.pooledTokens(address(fixture.weth));
        assertEq(liquidReserves, AMOUNT_TO_LP);

        // Counters should move once the root bundle is executed.
        _executeLeaf(leaf, MerkleTreeUtils.emptyProof());
        (, , , utilizedReserves, liquidReserves, ) = fixture.hubPool.pooledTokens(address(fixture.weth));
        assertEq(liquidReserves, AMOUNT_TO_LP - TOKENS_SEND_TO_L2);
        assertEq(utilizedReserves, int256(TOKENS_SEND_TO_L2 + REALIZED_LP_FEES));

        // Calling sync again does nothing.
        _forceSync(address(fixture.weth));
        (, , , utilizedReserves, liquidReserves, ) = fixture.hubPool.pooledTokens(address(fixture.weth));
        assertEq(liquidReserves, AMOUNT_TO_LP - TOKENS_SEND_TO_L2);
        assertEq(utilizedReserves, int256(TOKENS_SEND_TO_L2 + REALIZED_LP_FEES));

        // Next, move time forward past the end of the 1 week L2 liveness, say 10 days. At this point all fees should also
        // have been attributed to the LPs. The Exchange rate should update to (1000+10)/1000=1.01. Sync should still not
        // change anything as no tokens have been sent directly to the contracts (yet).
        vm.warp(block.timestamp + 10 * 24 * 60 * 60);
        assertEq(fixture.hubPool.exchangeRateCurrent(address(fixture.weth)), 1010000000000000000);
        _forceSync(address(fixture.weth));
        (, , , utilizedReserves, liquidReserves, ) = fixture.hubPool.pooledTokens(address(fixture.weth));
        assertEq(liquidReserves, AMOUNT_TO_LP - TOKENS_SEND_TO_L2);
        assertEq(utilizedReserves, int256(TOKENS_SEND_TO_L2 + REALIZED_LP_FEES));

        // Now, mimic the conclusion of the of the L2 -> l1 token transfer which pays back the LPs. The bundle of relays
        // executed on L2 constituted a relayer repayment of 100 tokens. The LPs should now have received 100 tokens + the
        // realizedLp fees of 10 tokens. i.e there should be a transfer of 110 tokens from L2->L1. This is represented by
        // simply send the tokens to the hubPool. The sync method should correctly attribute this to the trackers
        vm.prank(dataWorker);
        fixture.weth.transfer(address(fixture.hubPool), TOKENS_SEND_TO_L2 + REALIZED_LP_FEES);

        _forceSync(address(fixture.weth));

        // Liquid reserves should now be the sum of original LPed amount + the realized fees. This should equal the amount
        // LPed minus the amount sent to L2, plus the amount sent back to L1 (they are equivalent).
        (, , , utilizedReserves, liquidReserves, ) = fixture.hubPool.pooledTokens(address(fixture.weth));
        assertEq(liquidReserves, AMOUNT_TO_LP + REALIZED_LP_FEES);
        assertEq(liquidReserves, AMOUNT_TO_LP - TOKENS_SEND_TO_L2 + TOKENS_SEND_TO_L2 + REALIZED_LP_FEES);

        // All funds have returned to L1. As a result, the utilizedReserves should now be 0.
        assertEq(utilizedReserves, 0);

        // Finally, the exchangeRate should not have changed, even though the token balance of the contract has changed.
        assertEq(fixture.hubPool.exchangeRateCurrent(address(fixture.weth)), 1010000000000000000);
    }

    function test_TokenBalanceTrackersSyncCorrectlyWhenTokensAreDroppedOntoTheContract() public {
        (, , , int256 utilizedReserves, uint256 liquidReserves, ) = fixture.hubPool.pooledTokens(address(fixture.weth));
        assertEq(liquidReserves, AMOUNT_TO_LP);
        assertEq(utilizedReserves, 0);
        assertEq(fixture.hubPool.exchangeRateCurrent(address(fixture.weth)), 1e18);

        uint256 amountToSend = 10 ether;
        vm.prank(dataWorker);
        fixture.weth.transfer(address(fixture.hubPool), amountToSend);

        // The token balances should now sync correctly. Liquid reserves should capture the new funds sent to the hubPool
        // and the utilizedReserves should be negative in size equal to the tokens dropped onto the contract.
        _forceSync(address(fixture.weth));
        (, , , utilizedReserves, liquidReserves, ) = fixture.hubPool.pooledTokens(address(fixture.weth));
        assertEq(liquidReserves, AMOUNT_TO_LP + amountToSend);
        assertEq(utilizedReserves, -int256(amountToSend));
        // Importantly the exchange rate should not have changed.
        assertEq(fixture.hubPool.exchangeRateCurrent(address(fixture.weth)), 1e18);
    }

    function test_LiquidityUtilizationCorrectlyTracksTheUtilizationOfLiquidity() public {
        // Liquidity utilization starts off at 0 before any actions are done.
        assertEq(fixture.hubPool.liquidityUtilizationCurrent(address(fixture.weth)), 0);

        // Execute a relayer refund. Check counters move accordingly.
        HubPoolInterface.PoolRebalanceLeaf memory leaf;
        bytes32 root;
        (leaf, root) = constructSingleChainTree(1);
        leaf.l1Tokens[0] = address(fixture.weth);

        // Recalculate root with correct token address
        root = keccak256(abi.encode(leaf));

        _proposeRootBundle(root);

        // Liquidity is not used until the relayerRefund is executed(i.e "pending" reserves are not considered).
        assertEq(fixture.hubPool.liquidityUtilizationCurrent(address(fixture.weth)), 0);
        _executeLeaf(leaf, MerkleTreeUtils.emptyProof());

        // Now that the liquidity is used (sent to L2) we should be able to find the utilization. This should simply be
        // the utilizedReserves / (liquidReserves + utilizedReserves) = 110 / (900 + 110) = 0.108910891089108910
        assertEq(fixture.hubPool.liquidityUtilizationCurrent(address(fixture.weth)), 108910891089108910);

        // Advance time such that all LP fees have been paid out. Liquidity utilization should not have changed.
        vm.warp(block.timestamp + 10 * 24 * 60 * 60);
        assertEq(fixture.hubPool.exchangeRateCurrent(address(fixture.weth)), 1010000000000000000);
        assertEq(fixture.hubPool.liquidityUtilizationCurrent(address(fixture.weth)), 108910891089108910);
        _forceSync(address(fixture.weth));
        (, , , int256 utilizedReserves, uint256 liquidReserves, ) = fixture.hubPool.pooledTokens(address(fixture.weth));
        assertEq(liquidReserves, AMOUNT_TO_LP - TOKENS_SEND_TO_L2);
        assertEq(utilizedReserves, int256(TOKENS_SEND_TO_L2 + REALIZED_LP_FEES));

        // Now say that the LPs remove half their liquidity(withdraw 500 LP tokens). Removing half the LP tokens should send
        // back 500*1.01=505 tokens to the liquidity provider. Validate that the expected tokens move.
        uint256 amountToWithdraw = 500 ether;
        uint256 tokensReturnedForWithdrawnLpTokens = (amountToWithdraw * 1010000000000000000) / 1e18;

        // Approve LP tokens for burning
        vm.prank(liquidityProvider);
        wethLpToken.approve(address(fixture.hubPool), amountToWithdraw);

        uint256 balanceBefore = fixture.weth.balanceOf(liquidityProvider);
        vm.prank(liquidityProvider);
        fixture.hubPool.removeLiquidity(address(fixture.weth), amountToWithdraw, false);
        uint256 balanceAfter = fixture.weth.balanceOf(liquidityProvider);
        assertEq(balanceAfter - balanceBefore, tokensReturnedForWithdrawnLpTokens);

        // Pool trackers should update accordingly.
        _forceSync(address(fixture.weth));
        // Liquid reserves should now be the original LPed amount, minus that sent to l2, minus the fees removed from the
        // pool due to redeeming the LP tokens as 1000-100-500*1.01=395. Utilized reserves should not change.
        (, , , utilizedReserves, liquidReserves, ) = fixture.hubPool.pooledTokens(address(fixture.weth));
        assertEq(liquidReserves, AMOUNT_TO_LP - TOKENS_SEND_TO_L2 - tokensReturnedForWithdrawnLpTokens);
        assertEq(utilizedReserves, int256(TOKENS_SEND_TO_L2 + REALIZED_LP_FEES));

        // The associated liquidity utilization should be utilizedReserves / (liquidReserves + utilizedReserves) as
        // (110) / (395 + 110) = 0.217821782178217821
        assertEq(fixture.hubPool.liquidityUtilizationCurrent(address(fixture.weth)), 217821782178217821);

        // Now, mint tokens to mimic the finalization of the relay. The utilization should go back to 0.
        vm.prank(dataWorker);
        fixture.weth.transfer(address(fixture.hubPool), TOKENS_SEND_TO_L2 + REALIZED_LP_FEES);
        assertEq(fixture.hubPool.liquidityUtilizationCurrent(address(fixture.weth)), 0);
    }

    function test_LiquidityUtilizationIsAlwaysFlooredAt0EvenIfTokensAreDroppedOntoTheContract() public {
        assertEq(fixture.hubPool.liquidityUtilizationCurrent(address(fixture.weth)), 0);
        vm.prank(dataWorker);
        fixture.weth.transfer(address(fixture.hubPool), 500 ether);
        assertEq(fixture.hubPool.liquidityUtilizationCurrent(address(fixture.weth)), 0);

        // Seeing tokens were gifted onto the contract in size greater than the actual utilized reserves utilized reserves is
        // floored to 0. The utilization equation is therefore relayedAmount / liquidReserves. For a relay of 100 units,
        // the utilization should therefore be 100 / 1500 = 0.06666666666666667.
        assertEq(fixture.hubPool.liquidityUtilizationPostRelay(address(fixture.weth), 100 ether), 66666666666666666);

        // A larger relay of 600 should be 600/ 1500 = 0.4
        assertEq(fixture.hubPool.liquidityUtilizationPostRelay(address(fixture.weth), 600 ether), 400000000000000000);
    }

    function test_LiquidityUtilizationPostRelayCorrectlyComputesExpectedUtilizationForAGivenRelaySize() public {
        assertEq(fixture.hubPool.liquidityUtilizationCurrent(address(fixture.weth)), 0);
        assertEq(fixture.hubPool.liquidityUtilizationPostRelay(address(fixture.weth), 0), 0);

        // A relay of 100 Tokens should result in a liquidity utilization of 100 / (900 + 100) = 0.1.
        assertEq(fixture.hubPool.liquidityUtilizationPostRelay(address(fixture.weth), 100 ether), 100000000000000000);

        // Execute a relay refund bundle to increase the liquidity utilization.
        HubPoolInterface.PoolRebalanceLeaf memory leaf;
        bytes32 root;
        (leaf, root) = constructSingleChainTree(1);
        leaf.l1Tokens[0] = address(fixture.weth);

        // Recalculate root with correct token address
        root = keccak256(abi.encode(leaf));

        _proposeRootBundle(root);

        // Liquidity is not used until the relayerRefund is executed(i.e "pending" reserves are not considered).
        assertEq(fixture.hubPool.liquidityUtilizationCurrent(address(fixture.weth)), 0);
        _executeLeaf(leaf, MerkleTreeUtils.emptyProof());

        // Now that the liquidity is used (sent to L2) we should be able to find the utilization. This should simply be
        // the utilizedReserves / (liquidReserves + utilizedReserves) = 110 / (900 + 110) = 0.108910891089108910
        assertEq(fixture.hubPool.liquidityUtilizationCurrent(address(fixture.weth)), 108910891089108910);
    }

    function test_HighLiquidityUtilizationBlocksLPsFromWithdrawing() public {
        // Execute a relayer refund bundle. Set the scalingSize to 5. This will use 500 ETH from the hubPool.
        HubPoolInterface.PoolRebalanceLeaf memory leaf;
        bytes32 root;
        (leaf, root) = constructSingleChainTree(5);
        leaf.l1Tokens[0] = address(fixture.weth);

        // Recalculate root with correct token address
        root = keccak256(abi.encode(leaf));

        _proposeRootBundle(root);
        _executeLeaf(leaf, MerkleTreeUtils.emptyProof());
        vm.warp(block.timestamp + 10 * 24 * 60 * 60); // Move time to accumulate all fees.

        // Liquidity utilization should now be (550) / (500 + 550) = 0.523809523809523809. I.e utilization is over 50%.
        assertEq(fixture.hubPool.liquidityUtilizationCurrent(address(fixture.weth)), 523809523809523809);

        // Now, trying to withdraw 51% of the liquidity in an LP position should revert.
        vm.prank(liquidityProvider);
        vm.expectRevert();
        fixture.hubPool.removeLiquidity(address(fixture.weth), 501 ether, false);

        // Can remove exactly at the 50% mark, removing all free liquidity.
        uint256 currentExchangeRate = fixture.hubPool.exchangeRateCurrent(address(fixture.weth));
        assertEq(currentExchangeRate, 1050000000000000000);
        // Calculate the absolute maximum LP tokens that can be redeemed as the 500 tokens that we know are liquid in the
        // contract (we used 500 in the relayer refund) divided by the exchange rate. Add one wei as this operation will
        // round down. We can check that this redemption amount will return exactly 500 tokens.
        uint256 maxRedeemableLpTokens = (500 ether * 1e18) / currentExchangeRate + 1;

        // Approve LP tokens for burning
        vm.prank(liquidityProvider);
        wethLpToken.approve(address(fixture.hubPool), maxRedeemableLpTokens);

        uint256 balanceBefore = fixture.weth.balanceOf(liquidityProvider);
        vm.prank(liquidityProvider);
        fixture.hubPool.removeLiquidity(address(fixture.weth), maxRedeemableLpTokens, false); // redeem
        uint256 balanceAfter = fixture.weth.balanceOf(liquidityProvider);
        assertEq(balanceAfter - balanceBefore, 500 ether); // should send back exactly 500 tokens.

        // After this, the liquidity utilization should be exactly 100% with 0 tokens left in the contract.
        assertEq(fixture.hubPool.liquidityUtilizationCurrent(address(fixture.weth)), 1e18);
        assertEq(fixture.weth.balanceOf(address(fixture.hubPool)), 0);

        // Trying to remove even 1 wei should fail.
        vm.prank(liquidityProvider);
        vm.expectRevert();
        fixture.hubPool.removeLiquidity(address(fixture.weth), 1, false);
    }

    function test_RedeemingAllLPTokensAfterAccruingFeesIsHandledCorrectly() public {
        HubPoolInterface.PoolRebalanceLeaf memory leaf;
        bytes32 root;
        (leaf, root) = constructSingleChainTree(1);
        leaf.l1Tokens[0] = address(fixture.weth);

        // Recalculate root with correct token address
        root = keccak256(abi.encode(leaf));

        _proposeRootBundle(root);
        _executeLeaf(leaf, MerkleTreeUtils.emptyProof());
        vm.warp(block.timestamp + 10 * 24 * 60 * 60); // Move time to accumulate all fees.

        // Send back to L1 the tokensSendToL2 + realizedLpFees, i.e to mimic the finalization of the relay.
        vm.prank(dataWorker);
        fixture.weth.transfer(address(fixture.hubPool), TOKENS_SEND_TO_L2 + REALIZED_LP_FEES);

        // Exchange rate should be 1.01 (accumulated 10 WETH on 1000 WETH worth of liquidity). Utilization should be 0.
        assertEq(fixture.hubPool.exchangeRateCurrent(address(fixture.weth)), 1010000000000000000);
        assertEq(fixture.hubPool.liquidityUtilizationCurrent(address(fixture.weth)), 0);

        // Approve LP tokens for burning
        vm.prank(liquidityProvider);
        wethLpToken.approve(address(fixture.hubPool), AMOUNT_TO_LP);

        // Now, trying to all liquidity.
        vm.prank(liquidityProvider);
        fixture.hubPool.removeLiquidity(address(fixture.weth), AMOUNT_TO_LP, false);

        // Exchange rate is now set to 1.0 as all fees have been withdrawn.
        assertEq(fixture.hubPool.exchangeRateCurrent(address(fixture.weth)), 1e18);
        _forceSync(address(fixture.weth));
        (, , , int256 utilizedReserves, uint256 liquidReserves, uint256 undistributedLpFees) = fixture
            .hubPool
            .pooledTokens(address(fixture.weth));
        assertEq(liquidReserves, 0);
        assertEq(utilizedReserves, 0);
        assertEq(undistributedLpFees, 0);

        // Now, mint LP tokens again. The exchange rate should be re-set to 0 and have no memory of the previous deposits.
        vm.prank(liquidityProvider);
        fixture.weth.approve(address(fixture.hubPool), AMOUNT_TO_LP);
        vm.prank(liquidityProvider);
        fixture.hubPool.addLiquidity(address(fixture.weth), AMOUNT_TO_LP);

        // Exchange rate should be 1.0 as all fees have been withdrawn.
        assertEq(fixture.hubPool.exchangeRateCurrent(address(fixture.weth)), 1e18);

        // Going through a full refund lifecycle does returns to where we were before, with no memory of previous fees.
        _proposeRootBundle(root);
        _executeLeaf(leaf, MerkleTreeUtils.emptyProof());
        // Note: Use getCurrentTime() instead of block.timestamp because block.timestamp may not reflect
        // the warp that happened inside _proposeRootBundle due to Foundry's handling of vm.warp in internal calls.
        vm.warp(fixture.hubPool.getCurrentTime() + 10 * 24 * 60 * 60); // Move time to accumulate all fees.

        // Exchange rate should be 1.01, with 1% accumulated on the back of refunds with no memory of the previous fees.
        // Note: We don't send tokens back here (unlike first cycle) because we're testing that fees accumulate
        // even when tokens are still on L2. The exchange rate should reflect accumulated fees.
        // After warping 10 days, _updateAccumulatedLpFees should move all fees from undistributedLpFees,
        // so exchange rate = (liquidReserves + utilizedReserves - 0) / lpTokenSupply = (900 + 110) / 1000 = 1.01
        assertEq(fixture.hubPool.exchangeRateCurrent(address(fixture.weth)), 1010000000000000000);
    }
}
