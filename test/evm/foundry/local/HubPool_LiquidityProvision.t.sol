// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";
import { HubPoolTestBase } from "../utils/HubPoolTestBase.sol";
import { MintableERC20 } from "../../../../contracts/test/MockERC20.sol";
import { IERC20 } from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";

/**
 * @title HubPool_LiquidityProvisionTest
 * @notice Foundry tests for HubPool liquidity provision, ported from Hardhat tests.
 */
contract HubPool_LiquidityProvisionTest is HubPoolTestBase {
    // ============ Test Infrastructure ============

    address owner;
    address liquidityProvider;
    address other;

    MintableERC20 wethLpToken;
    MintableERC20 usdcLpToken;
    MintableERC20 daiLpToken;

    // ============ Constants ============

    uint256 constant AMOUNT_TO_SEED_WALLETS = 1500 ether;

    // ============ Setup ============

    function setUp() public {
        // Create base fixture (deploys HubPool, WETH, tokens, UMA mocks)
        createHubPoolFixture();

        // Create test accounts
        owner = address(this); // Test contract is owner
        liquidityProvider = makeAddr("liquidityProvider");
        other = makeAddr("other");

        // Enable tokens for LP (creates LP tokens)
        fixture.hubPool.enableL1TokenForLiquidityProvision(address(fixture.weth));
        fixture.hubPool.enableL1TokenForLiquidityProvision(address(fixture.usdc));
        fixture.hubPool.enableL1TokenForLiquidityProvision(address(fixture.dai));

        // Get LP token addresses
        (address wethLpTokenAddr, , , , , ) = fixture.hubPool.pooledTokens(address(fixture.weth));
        (address usdcLpTokenAddr, , , , , ) = fixture.hubPool.pooledTokens(address(fixture.usdc));
        (address daiLpTokenAddr, , , , , ) = fixture.hubPool.pooledTokens(address(fixture.dai));

        wethLpToken = MintableERC20(wethLpTokenAddr);
        usdcLpToken = MintableERC20(usdcLpTokenAddr);
        daiLpToken = MintableERC20(daiLpTokenAddr);

        // Seed liquidity provider with tokens and ETH
        fixture.usdc.mint(liquidityProvider, AMOUNT_TO_SEED_WALLETS);
        fixture.dai.mint(liquidityProvider, AMOUNT_TO_SEED_WALLETS);
        seedUserWithWeth(liquidityProvider, AMOUNT_TO_SEED_WALLETS);
    }

    // ============ Tests ============

    function test_AddingERC20Liquidity_CorrectlyPullsTokensAndMintsLPTokens() public {
        // Balances of collateral before should equal the seed amount and there should be 0 outstanding LP tokens.
        assertEq(fixture.dai.balanceOf(liquidityProvider), AMOUNT_TO_SEED_WALLETS);
        assertEq(daiLpToken.balanceOf(liquidityProvider), 0);

        vm.prank(liquidityProvider);
        fixture.dai.approve(address(fixture.hubPool), AMOUNT_TO_LP);
        vm.prank(liquidityProvider);
        fixture.hubPool.addLiquidity(address(fixture.dai), AMOUNT_TO_LP);

        // The balance of the collateral should be equal to the original amount minus the LPed amount. The balance of LP
        // tokens should be equal to the amount of LP tokens divided by the exchange rate current. This rate starts at 1e18,
        // so this should equal the amount minted.
        assertEq(fixture.dai.balanceOf(liquidityProvider), AMOUNT_TO_SEED_WALLETS - AMOUNT_TO_LP);
        assertEq(daiLpToken.balanceOf(liquidityProvider), AMOUNT_TO_LP);
        assertEq(daiLpToken.totalSupply(), AMOUNT_TO_LP);
    }

    function test_RemovingERC20Liquidity_BurnsLPTokensAndReturnsCollateral() public {
        vm.prank(liquidityProvider);
        fixture.dai.approve(address(fixture.hubPool), AMOUNT_TO_LP);
        vm.prank(liquidityProvider);
        fixture.hubPool.addLiquidity(address(fixture.dai), AMOUNT_TO_LP);

        // Approve LP tokens for burning
        vm.prank(liquidityProvider);
        daiLpToken.approve(address(fixture.hubPool), AMOUNT_TO_LP);

        // Next, try remove half the liquidity. This should modify the balances, as expected.
        vm.prank(liquidityProvider);
        fixture.hubPool.removeLiquidity(address(fixture.dai), AMOUNT_TO_LP / 2, false);

        assertEq(fixture.dai.balanceOf(liquidityProvider), AMOUNT_TO_SEED_WALLETS - AMOUNT_TO_LP / 2);
        assertEq(daiLpToken.balanceOf(liquidityProvider), AMOUNT_TO_LP / 2);
        assertEq(daiLpToken.totalSupply(), AMOUNT_TO_LP / 2);

        // Removing more than the total balance of LP tokens should throw.
        vm.expectRevert();
        vm.prank(other);
        fixture.hubPool.removeLiquidity(address(fixture.dai), AMOUNT_TO_LP, false);

        // Cant try receive ETH if the token is pool token is not WETH.
        vm.expectRevert();
        vm.prank(other);
        fixture.hubPool.removeLiquidity(address(fixture.dai), AMOUNT_TO_LP / 2, true);

        // Can remove the remaining LP tokens for a balance of 0. Use the same params as the above reverted call to show
        // that only the sendEth param needs to be changed.
        vm.prank(liquidityProvider);
        fixture.hubPool.removeLiquidity(address(fixture.dai), AMOUNT_TO_LP / 2, false);
        assertEq(fixture.dai.balanceOf(liquidityProvider), AMOUNT_TO_SEED_WALLETS); // back to starting balance.
        assertEq(daiLpToken.balanceOf(liquidityProvider), 0); // All LP tokens burnt.
        assertEq(daiLpToken.totalSupply(), 0);
    }

    function test_AddingETHLiquidity_CorrectlyWrapsToWETHAndMintsLPTokens() public {
        // Depositor can send WETH, if they have. Explicitly set the value to 0 to ensure we dont send any eth with the tx.
        uint256 initialWethTotalSupply = fixture.weth.totalSupply();
        vm.prank(liquidityProvider);
        fixture.weth.approve(address(fixture.hubPool), AMOUNT_TO_LP);
        vm.prank(liquidityProvider);
        fixture.hubPool.addLiquidity(address(fixture.weth), AMOUNT_TO_LP);
        assertEq(fixture.weth.balanceOf(liquidityProvider), AMOUNT_TO_SEED_WALLETS - AMOUNT_TO_LP);
        assertEq(wethLpToken.balanceOf(liquidityProvider), AMOUNT_TO_LP);

        // Next, try depositing ETH with the transaction. No WETH should be sent. The ETH send with the TX should be
        // wrapped for the user and LP tokens minted. Send the deposit and check the ether balance changes as expected.
        uint256 wethEthBalanceBefore = address(fixture.weth).balance;
        uint256 liquidityProviderEthBefore = liquidityProvider.balance;

        // Need to fund the liquidityProvider with ETH for the second deposit (they have 0 ETH since all was wrapped)
        vm.deal(liquidityProvider, AMOUNT_TO_LP);
        vm.prank(liquidityProvider);
        fixture.hubPool.addLiquidity{ value: AMOUNT_TO_LP }(address(fixture.weth), AMOUNT_TO_LP);

        // WETH's Ether balance should increase by the amount LPed.
        assertEq(address(fixture.weth).balance, wethEthBalanceBefore + AMOUNT_TO_LP);
        // The weth Token balance should have stayed the same as no weth was spent.
        assertEq(fixture.weth.balanceOf(liquidityProvider), AMOUNT_TO_SEED_WALLETS - AMOUNT_TO_LP);
        // However, the WETH LP token should have increase by the amount of LP tokens minted, as 2 x amountToLp.
        assertEq(wethLpToken.balanceOf(liquidityProvider), AMOUNT_TO_LP * 2);
        // Equally, the total WETH supply should have increased by the amount of LP tokens minted as they were deposited.
        assertEq(wethLpToken.totalSupply(), AMOUNT_TO_LP * 2);
        // WETH totalSupply should be initial supply + amount deposited in second addLiquidity (which wraps ETH to WETH)
        assertEq(fixture.weth.totalSupply(), initialWethTotalSupply + AMOUNT_TO_LP);
    }

    function test_RemovingETHLiquidity_CanSendBackWETHOrETHDependingOnUsersChoice() public {
        vm.prank(liquidityProvider);
        fixture.weth.approve(address(fixture.hubPool), AMOUNT_TO_LP);
        vm.prank(liquidityProvider);
        fixture.hubPool.addLiquidity(address(fixture.weth), AMOUNT_TO_LP);

        // Approve LP tokens for burning
        vm.prank(liquidityProvider);
        wethLpToken.approve(address(fixture.hubPool), AMOUNT_TO_LP);

        // Remove half the liquidity as WETH (set sendETH = false). This should modify the weth bal and not the eth bal.
        uint256 liquidityProviderEthBefore = liquidityProvider.balance;
        uint256 liquidityProviderWethBefore = fixture.weth.balanceOf(liquidityProvider);

        vm.prank(liquidityProvider);
        fixture.hubPool.removeLiquidity(address(fixture.weth), AMOUNT_TO_LP / 2, false);

        assertEq(liquidityProvider.balance, liquidityProviderEthBefore); // ETH balance unchanged
        assertEq(fixture.weth.balanceOf(liquidityProvider), liquidityProviderWethBefore + AMOUNT_TO_LP / 2); // WETH balance should increase by the amount removed.

        // Next, remove half the liquidity as ETH (set sendETH = true). This should modify the eth bal but not the weth bal.
        liquidityProviderWethBefore = fixture.weth.balanceOf(liquidityProvider);
        liquidityProviderEthBefore = liquidityProvider.balance;

        vm.prank(liquidityProvider);
        fixture.hubPool.removeLiquidity(address(fixture.weth), AMOUNT_TO_LP / 2, true);

        assertEq(liquidityProvider.balance, liquidityProviderEthBefore + AMOUNT_TO_LP / 2); // There should be ETH transferred, not WETH.
        assertEq(fixture.weth.balanceOf(liquidityProvider), liquidityProviderWethBefore); // weth balance stayed the same.

        // There should be no LP tokens left outstanding:
        assertEq(wethLpToken.balanceOf(liquidityProvider), 0);
    }

    function test_AddingAndRemovingNon18DecimalCollateral_MintsCommensurateAmountOfLPTokens() public {
        // USDC is 6 decimal places. Scale the amountToLp back to a normal number then up by 6 decimal places to get a 1e6
        // scaled number. i.e amountToLp is 1000 so this number will be 1e9.
        // amountToLp = 1000 ether = 1000 * 1e18 = 1e21
        // fromWei(amountToLp) = 1000
        // scaledAmountToLp = 1000 * 1e6 = 1e9
        uint256 scaledAmountToLp = (AMOUNT_TO_LP / 1e12) * 1e6; // Convert from 18 decimals to 6 decimals

        vm.prank(liquidityProvider);
        fixture.usdc.approve(address(fixture.hubPool), scaledAmountToLp);
        vm.prank(liquidityProvider);
        fixture.hubPool.addLiquidity(address(fixture.usdc), scaledAmountToLp);

        // Check the balances are correct.
        assertEq(usdcLpToken.balanceOf(liquidityProvider), scaledAmountToLp);
        assertEq(fixture.usdc.balanceOf(liquidityProvider), AMOUNT_TO_SEED_WALLETS - scaledAmountToLp);
        assertEq(fixture.usdc.balanceOf(address(fixture.hubPool)), scaledAmountToLp);

        // Approve LP tokens for burning
        vm.prank(liquidityProvider);
        usdcLpToken.approve(address(fixture.hubPool), scaledAmountToLp);

        // Redemption should work as normal, just scaled.
        vm.prank(liquidityProvider);
        fixture.hubPool.removeLiquidity(address(fixture.usdc), scaledAmountToLp / 2, false);
        assertEq(usdcLpToken.balanceOf(liquidityProvider), scaledAmountToLp / 2);
        assertEq(fixture.usdc.balanceOf(liquidityProvider), AMOUNT_TO_SEED_WALLETS - scaledAmountToLp / 2);
        assertEq(fixture.usdc.balanceOf(address(fixture.hubPool)), scaledAmountToLp / 2);
    }

    function test_Pause_DisablesAnyLiquidityAction() public {
        fixture.hubPool.setPaused(true);
        vm.prank(liquidityProvider);
        fixture.weth.approve(address(fixture.hubPool), AMOUNT_TO_LP);
        vm.expectRevert("Contract is paused");
        vm.prank(liquidityProvider);
        fixture.hubPool.addLiquidity(address(fixture.weth), AMOUNT_TO_LP);
        vm.expectRevert("Contract is paused");
        vm.prank(liquidityProvider);
        fixture.hubPool.removeLiquidity(address(fixture.weth), AMOUNT_TO_LP, false);
    }
}
