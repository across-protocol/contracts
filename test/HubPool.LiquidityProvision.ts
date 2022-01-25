import { expect } from "chai";
import { Contract } from "ethers";
import { ethers } from "hardhat";
import { getContractFactory } from "./utils";
import { deployHubPoolTestHelperContracts, seedWallet } from "./HubPool.Fixture";
import { amountToSeedWallets, amountToLp } from "./HubPool.constants";

let hubPool: Contract, weth: Contract, usdc: Contract, dai: Contract;
let owner: any, liquidityProvider: any, other: any;

describe("HubPool Liquidity Provision", function () {
  beforeEach(async function () {
    [owner, liquidityProvider, other] = await ethers.getSigners();
    ({ weth, usdc, dai, hubPool } = await deployHubPoolTestHelperContracts(owner));
    await hubPool.enableL1TokenForLiquidityProvision(weth.address);
    await hubPool.enableL1TokenForLiquidityProvision(usdc.address);
    await hubPool.enableL1TokenForLiquidityProvision(dai.address);

    // mint some fresh tokens and deposit ETH for weth for the liquidity provider.
    await seedWallet(liquidityProvider, [usdc, dai], weth, amountToSeedWallets);
  });

  it("Adding ER20 liquidity correctly pulls tokens and mints LP tokens", async function () {
    const daiLpToken = await (
      await getContractFactory("ExpandedERC20", owner)
    ).attach((await hubPool.callStatic.lpTokens(dai.address)).lpToken);

    // Balances of collateral before should equal the seed amount and there should be 0 outstanding LP tokens.
    expect(await dai.balanceOf(liquidityProvider.address)).to.equal(amountToSeedWallets);
    expect(await daiLpToken.balanceOf(liquidityProvider.address)).to.equal(0);

    await dai.connect(liquidityProvider).approve(hubPool.address, amountToLp);
    await hubPool.connect(liquidityProvider).addLiquidity(dai.address, amountToLp);

    //The balance of the collateral should be equal to the original amount minus the LPed amount. The balance of LP
    // tokens should be equal to the amount of LP tokens divided by the exchange rate current. This rate starts at 1e18,
    // so this should equal the amount minted.
    expect(await dai.balanceOf(liquidityProvider.address)).to.equal(amountToSeedWallets.sub(amountToLp));
    expect(await daiLpToken.balanceOf(liquidityProvider.address)).to.equal(amountToLp);
    expect(await daiLpToken.totalSupply()).to.equal(amountToLp);
  });
  it("Removing ER20 liquidity burns LP tokens and returns collateral", async function () {
    const daiLpToken = await (
      await getContractFactory("ExpandedERC20", owner)
    ).attach((await hubPool.callStatic.lpTokens(dai.address)).lpToken);

    await dai.connect(liquidityProvider).approve(hubPool.address, amountToLp);
    await hubPool.connect(liquidityProvider).addLiquidity(dai.address, amountToLp);

    // Next, try remove half the liquidity. This should modify the balances, as expected.
    await hubPool.connect(liquidityProvider).removeLiquidity(dai.address, amountToLp.div(2), false);

    expect(await dai.balanceOf(liquidityProvider.address)).to.equal(amountToSeedWallets.sub(amountToLp.div(2)));
    expect(await daiLpToken.balanceOf(liquidityProvider.address)).to.equal(amountToLp.div(2));
    expect(await daiLpToken.totalSupply()).to.equal(amountToLp.div(2));

    // Removing more than the total balance of LP tokens should throw.
    await expect(hubPool.connect(other).removeLiquidity(dai.address, amountToLp, false)).to.be.reverted;

    // Cant try receive ETH if the token is pool token is not WETH. Try redeem 1/3 of the original amount added. This is
    // less than the total amount the wallet has left (since we removed half the amount before).
    await expect(hubPool.connect(other).removeLiquidity(dai.address, amountToLp.div(3), true)).to.be.reverted;

    //Can remove the remaining LP tokens for a balance of 0.
    await hubPool.connect(liquidityProvider).removeLiquidity(dai.address, amountToLp.div(2), false);
    expect(await dai.balanceOf(liquidityProvider.address)).to.equal(amountToSeedWallets); // back to starting balance.
    expect(await daiLpToken.balanceOf(liquidityProvider.address)).to.equal(0); // All LP tokens burnt.
    expect(await daiLpToken.totalSupply()).to.equal(0);
  });
});
