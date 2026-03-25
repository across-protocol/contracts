// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";
import { HubPoolTestBase } from "../utils/HubPoolTestBase.sol";
import { MerkleTreeUtils } from "../utils/MerkleTreeUtils.sol";
import { HubPoolInterface } from "../../../../contracts/interfaces/HubPoolInterface.sol";
import { MintableERC20 } from "../../../../contracts/test/MockERC20.sol";
import { Mock_Adapter } from "../../../../contracts/chain-adapters/Mock_Adapter.sol";

/**
 * @title HubPool_LiquidityProvisionFeesTest
 * @notice Foundry tests for HubPool liquidity provision fees.
 */
contract HubPool_LiquidityProvisionFeesTest is HubPoolTestBase {
    // ============ Test Infrastructure ============

    address owner;
    address dataWorker;
    address liquidityProvider;

    MintableERC20 wethLpToken;
    Mock_Adapter mockAdapter;
    address mockSpoke;

    // ============ Constants ============

    // ============ Setup ============

    function setUp() public {
        // Create base fixture (deploys HubPool, WETH, tokens, UMA mocks)
        createHubPoolFixture();

        // Create test accounts
        owner = address(this); // Test contract is owner
        dataWorker = makeAddr("dataWorker");
        liquidityProvider = makeAddr("liquidityProvider");

        // Seed dataWorker with WETH (bondAmount + finalFee) * 2
        seedUserWithWeth(dataWorker, TOTAL_BOND * 2);

        // Seed liquidityProvider with WETH amountToLp * 10
        seedUserWithWeth(liquidityProvider, AMOUNT_TO_LP * 10);

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

    // ============ Tests ============

    function test_FeeTrackingVariables_AreCorrectlyUpdatedAtExecutionOfRefund() public {
        // Before any execution happens liquidity trackers are set as expected.
        (
            ,
            ,
            uint32 lastLpFeeUpdate,
            int256 utilizedReserves,
            uint256 liquidReserves,
            uint256 undistributedLpFees
        ) = fixture.hubPool.pooledTokens(address(fixture.weth));
        assertEq(liquidReserves, AMOUNT_TO_LP);
        assertEq(utilizedReserves, 0);
        assertEq(undistributedLpFees, 0);
        assertEq(lastLpFeeUpdate, block.timestamp);

        // Construct the tree with WETH
        (HubPoolInterface.PoolRebalanceLeaf memory leaf, bytes32 root) = MerkleTreeUtils.buildSingleTokenLeaf(
            REPAYMENT_CHAIN_ID,
            address(fixture.weth),
            TOKENS_TO_SEND,
            LP_FEES
        );

        vm.prank(dataWorker);
        proposeBundleAndAdvanceTime(root, MOCK_RELAYER_REFUND_ROOT, MOCK_SLOW_RELAY_ROOT);
        executeLeaf(leaf, MerkleTreeUtils.emptyProof());

        // Validate the post execution values have updated as expected. Liquid reserves should be the original LPed amount
        // minus the amount sent to L2. Utilized reserves should be the amount sent to L2 plus the attribute to LPs.
        // Undistributed LP fees should be attribute to LPs.
        (, , , utilizedReserves, liquidReserves, undistributedLpFees) = fixture.hubPool.pooledTokens(
            address(fixture.weth)
        );
        assertEq(liquidReserves, AMOUNT_TO_LP - TOKENS_TO_SEND);
        // UtilizedReserves contains both the amount sent to L2 and the attributed LP fees.
        assertEq(utilizedReserves, int256(TOKENS_TO_SEND + LP_FEES));
        assertEq(undistributedLpFees, LP_FEES);
    }

    function test_ExchangeRateCurrent_CorrectlyAttributesFeesOverSmearPeriod() public {
        // Construct the tree with WETH
        (HubPoolInterface.PoolRebalanceLeaf memory leaf, bytes32 root) = MerkleTreeUtils.buildSingleTokenLeaf(
            REPAYMENT_CHAIN_ID,
            address(fixture.weth),
            TOKENS_TO_SEND,
            LP_FEES
        );

        // Exchange rate current before any fees are attributed execution should be 1.
        assertEq(fixture.hubPool.exchangeRateCurrent(address(fixture.weth)), 1e18);

        vm.prank(dataWorker);
        proposeBundleAndAdvanceTime(root, MOCK_RELAYER_REFUND_ROOT, MOCK_SLOW_RELAY_ROOT);
        executeLeaf(leaf, MerkleTreeUtils.emptyProof());

        // Exchange rate current right after the refund execution should be the amount deposited, grown by the 100 second
        // liveness period. Of the 10 ETH attributed to LPs, a total of 10*0.0000015*7201=0.108015 was attributed to LPs.
        // The exchange rate is therefore (1000+0.108015)/1000=1.000108015.
        assertEq(fixture.hubPool.exchangeRateCurrent(address(fixture.weth)), 1000108015000000000);

        // Validate the state variables are updated accordingly. In particular, undistributedLpFees should have decremented
        // by the amount allocated in the previous computation. This should be 10-0.108015=9.891985.
        (, , , int256 utilizedReserves, uint256 liquidReserves, uint256 undistributedLpFees) = fixture
            .hubPool
            .pooledTokens(address(fixture.weth));
        assertEq(undistributedLpFees, 9891985000000000000);

        // Next, advance time 2 days. Compute the ETH attributed to LPs by multiplying the original amount allocated(10),
        // minus the previous computation amount(0.108) by the smear rate, by the duration to get the second periods
        // allocation of(10 - 0.108015) * 0.0000015 * (172800)=2.564002512.The exchange rate should be The sum of the
        // liquidity provided and the fees added in both periods as (1000+0.108015+2.564002512)/1000=1.002672017512.
        vm.warp(block.timestamp + 2 * 24 * 60 * 60);
        assertEq(fixture.hubPool.exchangeRateCurrent(address(fixture.weth)), 1002672017512000000);

        // Again, we can validate that the undistributedLpFees have been updated accordingly. This should be set to the
        // original amount (10) minus the two sets of attributed LP fees as 10-0.108015-2.564002512=7.327982488.
        (, , , utilizedReserves, liquidReserves, undistributedLpFees) = fixture.hubPool.pooledTokens(
            address(fixture.weth)
        );
        assertEq(undistributedLpFees, 7327982488000000000);

        // Finally, advance time past the end of the smear period by moving forward 10 days. At this point all LP fees
        // should be attributed such that undistributedLpFees=0 and the exchange rate should simply be (1000+10)/1000=1.01.
        vm.warp(block.timestamp + 10 * 24 * 60 * 60);
        assertEq(fixture.hubPool.exchangeRateCurrent(address(fixture.weth)), 1010000000000000000);
        (, , , utilizedReserves, liquidReserves, undistributedLpFees) = fixture.hubPool.pooledTokens(
            address(fixture.weth)
        );
        assertEq(undistributedLpFees, 0);
    }
}
