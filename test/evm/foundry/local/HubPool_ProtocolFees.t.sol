// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";
import { HubPoolTestBase } from "../utils/HubPoolTestBase.sol";
import { MerkleTreeUtils } from "../utils/MerkleTreeUtils.sol";
import { HubPoolInterface } from "../../../../contracts/interfaces/HubPoolInterface.sol";
import { MintableERC20 } from "../../../../contracts/test/MockERC20.sol";
import { Mock_Adapter } from "../../../../contracts/chain-adapters/Mock_Adapter.sol";

/**
 * @title HubPool_ProtocolFeesTest
 * @notice Foundry tests for HubPool protocol fees, ported from Hardhat tests.
 */
contract HubPool_ProtocolFeesTest is HubPoolTestBase {
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

    bytes32 constant MOCK_TREE_ROOT = bytes32(uint256(0xabcd));

    uint256 constant INITIAL_PROTOCOL_FEE_CAPTURE_PCT = 0.1 ether; // 10%

    // ============ Setup ============

    function setUp() public {
        // Create base fixture (deploys HubPool, WETH, tokens, UMA mocks)
        createHubPoolFixture();

        // Create test accounts
        owner = address(this); // Test contract is owner
        dataWorker = makeAddr("dataWorker");
        liquidityProvider = makeAddr("liquidityProvider");

        // Seed dataWorker with WETH for bonds
        uint256 dataWorkerAmount = (BOND_AMOUNT + FINAL_FEE) * 2;
        vm.deal(dataWorker, dataWorkerAmount);
        vm.prank(dataWorker);
        fixture.weth.deposit{ value: dataWorkerAmount }();

        // Seed liquidityProvider with WETH
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

        // Set initial protocol fee capture
        fixture.hubPool.setProtocolFeeCapture(owner, INITIAL_PROTOCOL_FEE_CAPTURE_PCT);
    }

    // ============ Helper Functions ============

    /**
     * @notice Constructs a single-chain tree for testing.
     * @return leaf The pool rebalance leaf
     * @return root The merkle root
     */
    function constructSingleChainTree()
        internal
        view
        returns (HubPoolInterface.PoolRebalanceLeaf memory leaf, bytes32 root)
    {
        (leaf, root) = MerkleTreeUtils.buildSingleTokenLeaf(
            REPAYMENT_CHAIN_ID,
            address(fixture.weth),
            TOKENS_SEND_TO_L2,
            REALIZED_LP_FEES
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
            MOCK_TREE_ROOT,
            MOCK_TREE_ROOT
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

    // ============ Tests ============

    function test_OnlyOwnerCanSetProtocolFeeCapture() public {
        vm.prank(liquidityProvider);
        vm.expectRevert("Ownable: caller is not the owner");
        fixture.hubPool.setProtocolFeeCapture(liquidityProvider, 0.1 ether);
    }

    function test_CanChangeProtocolFeeCaptureSettings() public {
        assertEq(fixture.hubPool.protocolFeeCaptureAddress(), owner);
        assertEq(fixture.hubPool.protocolFeeCapturePct(), INITIAL_PROTOCOL_FEE_CAPTURE_PCT);

        uint256 newPct = 0.1 ether;

        // Can't set to 0 address
        vm.expectRevert("Bad protocolFeeCaptureAddress");
        fixture.hubPool.setProtocolFeeCapture(address(0), newPct);

        fixture.hubPool.setProtocolFeeCapture(liquidityProvider, newPct);
        assertEq(fixture.hubPool.protocolFeeCaptureAddress(), liquidityProvider);
        assertEq(fixture.hubPool.protocolFeeCapturePct(), newPct);
    }

    function test_WhenFeeCaptureNotZeroFeesCorrectlyAttributeBetweenLPsAndProtocol() public {
        (HubPoolInterface.PoolRebalanceLeaf memory leaf, bytes32 root) = constructSingleChainTree();

        _proposeRootBundle(root);
        _executeLeaf(leaf, MerkleTreeUtils.emptyProof());

        // 90% of the fees should be attributed to the LPs.
        (, , , , , uint256 undistributedLpFees) = fixture.hubPool.pooledTokens(address(fixture.weth));
        uint256 expectedLpFees = (REALIZED_LP_FEES * (1 ether - INITIAL_PROTOCOL_FEE_CAPTURE_PCT)) / 1 ether;
        assertEq(undistributedLpFees, expectedLpFees);

        // 10% of the fees should be attributed to the protocol.
        uint256 expectedProtocolFees = (REALIZED_LP_FEES * INITIAL_PROTOCOL_FEE_CAPTURE_PCT) / 1 ether;
        assertEq(fixture.hubPool.unclaimedAccumulatedProtocolFees(address(fixture.weth)), expectedProtocolFees);

        // Protocol should be able to claim their fees.
        uint256 ownerBalanceBefore = fixture.weth.balanceOf(owner);
        fixture.hubPool.claimProtocolFeesCaptured(address(fixture.weth));
        uint256 ownerBalanceAfter = fixture.weth.balanceOf(owner);
        assertEq(ownerBalanceAfter - ownerBalanceBefore, expectedProtocolFees);

        // After claiming, the protocol fees should be zero.
        assertEq(fixture.hubPool.unclaimedAccumulatedProtocolFees(address(fixture.weth)), 0);

        // Once all the fees have been attributed the correct amount should be claimable by the LPs.
        vm.warp(block.timestamp + 10 * 24 * 60 * 60); // Move time to accumulate all fees.
        fixture.hubPool.exchangeRateCurrent(address(fixture.weth)); // force state sync.
        (, , , , , undistributedLpFees) = fixture.hubPool.pooledTokens(address(fixture.weth));
        assertEq(undistributedLpFees, 0);
    }

    function test_WhenFeeCaptureZeroAllFeesAccumulateToLPs() public {
        fixture.hubPool.setProtocolFeeCapture(owner, 0);

        (HubPoolInterface.PoolRebalanceLeaf memory leaf, bytes32 root) = constructSingleChainTree();

        _proposeRootBundle(root);
        _executeLeaf(leaf, MerkleTreeUtils.emptyProof());

        (, , , , , uint256 undistributedLpFees) = fixture.hubPool.pooledTokens(address(fixture.weth));
        assertEq(undistributedLpFees, REALIZED_LP_FEES);

        vm.warp(block.timestamp + 10 * 24 * 60 * 60); // Move time to accumulate all fees.
        fixture.hubPool.exchangeRateCurrent(address(fixture.weth)); // force state sync.
        (, , , , , undistributedLpFees) = fixture.hubPool.pooledTokens(address(fixture.weth));
        assertEq(undistributedLpFees, 0);
        assertEq(fixture.hubPool.exchangeRateCurrent(address(fixture.weth)), 1.01 ether);
    }
}
