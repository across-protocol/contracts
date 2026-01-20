// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";
import { HubPoolTestBase } from "../utils/HubPoolTestBase.sol";
import { MerkleTreeUtils } from "../utils/MerkleTreeUtils.sol";
import { HubPoolInterface } from "../../../../contracts/interfaces/HubPoolInterface.sol";
import { MintableERC20 } from "../../../../contracts/test/MockERC20.sol";
import { Mock_Adapter } from "../../../../contracts/chain-adapters/Mock_Adapter.sol";

/**
 * @title HubPool_LiquidityProvisionHaircutTest
 * @notice Foundry tests for HubPool liquidity provision haircut.
 */
contract HubPool_LiquidityProvisionHaircutTest is HubPoolTestBase {
    // ============ Test Infrastructure ============

    address owner;
    address dataWorker;
    address liquidityProvider;

    MintableERC20 wethLpToken;
    Mock_Adapter mockAdapter;
    address mockSpoke;

    // ============ Constants ============

    uint256 constant TOKENS_SEND_TO_L2 = 100 ether;
    uint256 constant REALIZED_LP_FEES = 10 ether;

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

    function test_HaircutCanCorrectlyOffsetExchangeRateCurrentToEncapsulateLostTokens() public {
        // Construct the tree with WETH
        (HubPoolInterface.PoolRebalanceLeaf memory leaf, bytes32 root) = MerkleTreeUtils.buildSingleTokenLeaf(
            REPAYMENT_CHAIN_ID,
            address(fixture.weth),
            TOKENS_SEND_TO_L2,
            REALIZED_LP_FEES
        );

        vm.prank(dataWorker);
        proposeBundleAndAdvanceTime(root, MOCK_RELAYER_REFUND_ROOT, MOCK_SLOW_RELAY_ROOT);
        executeLeaf(leaf, MerkleTreeUtils.emptyProof());

        // Exchange rate current right after the refund execution should be the amount deposited, grown by the 100 second
        // liveness period. Of the 10 ETH attributed to LPs, a total of 10*0.0000015*7201=0.108015 was attributed to LPs.
        // The exchange rate is therefore (1000+0.108015)/1000=1.000108015.
        assertEq(fixture.hubPool.exchangeRateCurrent(address(fixture.weth)), 1000108015000000000);

        // At this point if all LP tokens are attempted to be redeemed at the provided exchange rate the call should fail
        // as the hub pool is currently waiting for funds to come back over the canonical bridge. they are lent out.
        // Approve LP tokens for burning (needed for burnFrom, even though the call will revert due to insufficient reserves)
        vm.prank(liquidityProvider);
        wethLpToken.approve(address(fixture.hubPool), AMOUNT_TO_LP);
        vm.prank(liquidityProvider);
        vm.expectRevert();
        fixture.hubPool.removeLiquidity(address(fixture.weth), AMOUNT_TO_LP, false);

        // Now, consider that the funds sent over the bridge (TOKENS_SEND_TO_L2) are actually lost due to the L2 breaking.
        // We now need to haircut the LPs be modifying the exchange rate current such that they get a commensurate
        // redemption rate against the lost funds.
        fixture.hubPool.haircutReserves(address(fixture.weth), int256(TOKENS_SEND_TO_L2));
        fixture.hubPool.sync(address(fixture.weth));

        // The exchange rate current should now factor in the loss of funds and should now be less than 1. Taking the amount
        // attributed to LPs in fees from the previous calculation and the 100 lost tokens, the exchangeRateCurrent should be:
        // (1000+0.108015-100)/1000=0.900108015.
        assertEq(fixture.hubPool.exchangeRateCurrent(address(fixture.weth)), 900108015000000000);

        // Now, advance time such that all accumulated rewards are accumulated.
        vm.warp(block.timestamp + 10 * 24 * 60 * 60);
        fixture.hubPool.exchangeRateCurrent(address(fixture.weth)); // force state sync.
        (, , , , , uint256 undistributedLpFees) = fixture.hubPool.pooledTokens(address(fixture.weth));
        assertEq(undistributedLpFees, 0);

        // Exchange rate should now be the (LPAmount + fees - lostTokens) / LPTokenSupply = (1000+10-100)/1000=0.91
        assertEq(fixture.hubPool.exchangeRateCurrent(address(fixture.weth)), 910000000000000000);
    }
}
