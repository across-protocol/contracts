import { getContractFactory, fromWei, toBN, SignerWithAddress, seedWallet, expect, Contract, ethers } from "./utils";
import { hubPoolFixture, enableTokensForLP } from "./HubPool.Fixture";
import { amountToSeedWallets, amountToLp } from "./constants";

let hubPool: Contract, weth: Contract, usdc: Contract, dai: Contract;
let wethLpToken: Contract, usdcLpToken: Contract, daiLpToken: Contract;
let owner: SignerWithAddress, liquidityProvider: SignerWithAddress, other: SignerWithAddress;

describe("HubPool Liquidity Provision", function () {
  beforeEach(async function () {
    [owner, liquidityProvider, other] = await ethers.getSigners();
    ({ weth, usdc, dai, hubPool } = await hubPoolFixture());
    [wethLpToken, usdcLpToken, daiLpToken] = await enableTokensForLP(owner, hubPool, weth, [weth, usdc, dai]);

    // mint some fresh tokens and deposit ETH for weth for the liquidity provider.
    await seedWallet(liquidityProvider, [usdc, dai], weth, amountToSeedWallets);
  });

  it("Adding ER20 liquidity correctly pulls tokens and mints LP tokens", async function () {
    const daiLpToken = await (
      await getContractFactory("ExpandedERC20", owner)
    ).attach((await hubPool.callStatic.pooledTokens(dai.address)).lpToken);

    // Balances of collateral before should equal the seed amount and there should be 0 outstanding LP tokens.
    expect(await dai.balanceOf(liquidityProvider.address)).to.equal(amountToSeedWallets);
    expect(await daiLpToken.balanceOf(liquidityProvider.address)).to.equal(0);

    await dai.connect(liquidityProvider).approve(hubPool.address, amountToLp);
    await hubPool.connect(liquidityProvider).addLiquidity(dai.address, amountToLp);

    // The balance of the collateral should be equal to the original amount minus the LPed amount. The balance of LP
    // tokens should be equal to the amount of LP tokens divided by the exchange rate current. This rate starts at 1e18,
    // so this should equal the amount minted.
    expect(await dai.balanceOf(liquidityProvider.address)).to.equal(amountToSeedWallets.sub(amountToLp));
    expect(await daiLpToken.balanceOf(liquidityProvider.address)).to.equal(amountToLp);
    expect(await daiLpToken.totalSupply()).to.equal(amountToLp);
  });
  it("Removing ER20 liquidity burns LP tokens and returns collateral", async function () {
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

    // Can remove the remaining LP tokens for a balance of 0.
    await hubPool.connect(liquidityProvider).removeLiquidity(dai.address, amountToLp.div(2), false);
    expect(await dai.balanceOf(liquidityProvider.address)).to.equal(amountToSeedWallets); // back to starting balance.
    expect(await daiLpToken.balanceOf(liquidityProvider.address)).to.equal(0); // All LP tokens burnt.
    expect(await daiLpToken.totalSupply()).to.equal(0);
  });
  it("Adding ETH liquidity correctly wraps to WETH and mints LP tokens", async function () {
    // Depositor can send WETH, if they have. Explicitly set the value to 0 to ensure we dont send any eth with the tx.
    await weth.connect(liquidityProvider).approve(hubPool.address, amountToLp);
    await hubPool.connect(liquidityProvider).addLiquidity(weth.address, amountToLp, { value: 0 });
    expect(await weth.balanceOf(liquidityProvider.address)).to.equal(amountToSeedWallets.sub(amountToLp));
    expect(await wethLpToken.balanceOf(liquidityProvider.address)).to.equal(amountToLp);

    // Next, try depositing ETH with the transaction. No WETH should be sent. The ETH send with the TX should be
    // wrapped for the user and LP tokens minted. Send the deposit and check the ether balance changes as expected.
    await expect(() =>
      hubPool.connect(liquidityProvider).addLiquidity(weth.address, amountToLp, { value: amountToLp })
    ).to.changeEtherBalance(weth, amountToLp); // WETH's Ether balance should increase by the amount LPed.
    // The weth Token balance should have stayed the same as no weth was spent.
    expect(await weth.balanceOf(liquidityProvider.address)).to.equal(amountToSeedWallets.sub(amountToLp));
    // However, the WETH LP token should have increase by the amount of LP tokens minted, as 2 x amountToLp.
    expect(await wethLpToken.balanceOf(liquidityProvider.address)).to.equal(amountToLp.mul(2));
    // Equally, the total WETH supply should have increased by the amount of LP tokens minted as they were deposited.
    expect(await wethLpToken.totalSupply()).to.equal(amountToLp.mul(2));
    expect(await weth.totalSupply()).to.equal(amountToLp.add(amountToSeedWallets));
  });

  it("Removing ETH liquidity can send back WETH or ETH depending on the users choice", async function () {
    await weth.connect(liquidityProvider).approve(hubPool.address, amountToLp);
    await hubPool.connect(liquidityProvider).addLiquidity(weth.address, amountToLp);

    // Remove half the liquidity as WETH (set sendETH = false). This should modify the weth bal and not the eth bal.
    await expect(() =>
      hubPool.connect(liquidityProvider).removeLiquidity(weth.address, amountToLp.div(2), false)
    ).to.changeEtherBalance(liquidityProvider, 0);

    expect(await weth.balanceOf(liquidityProvider.address)).to.equal(amountToSeedWallets.sub(amountToLp.div(2))); // WETH balance should increase by the amount removed.

    // Next, remove half the liquidity as ETH (set sendETH = true). This should modify the eth bal but not the weth bal.
    await expect(() =>
      hubPool.connect(liquidityProvider).removeLiquidity(weth.address, amountToLp.div(2), true)
    ).to.changeEtherBalance(liquidityProvider, amountToLp.div(2)); // There should be ETH transferred, not WETH.
    expect(await weth.balanceOf(liquidityProvider.address)).to.equal(amountToSeedWallets.sub(amountToLp.div(2))); // weth balance stayed the same.

    // There should be no LP tokens left outstanding:
    expect(await wethLpToken.balanceOf(liquidityProvider.address)).to.equal(0);
  });
  it("Adding and removing non-18 decimal collateral mints the commensurate amount of LP tokens", async function () {
    // USDC is 6 decimal places. Scale the amountToLp back to a normal number then up by 6 decimal places to get a 1e6
    // scaled number. i.e amountToLp is 1000 so this number will be 1e6.
    const scaledAmountToLp = toBN(fromWei(amountToLp)).mul(1e6); // USDC is 6 decimal places.
    await usdc.connect(liquidityProvider).approve(hubPool.address, amountToLp);
    await hubPool.connect(liquidityProvider).addLiquidity(usdc.address, scaledAmountToLp);

    // Check the balances are correct.
    expect(await usdcLpToken.balanceOf(liquidityProvider.address)).to.equal(scaledAmountToLp);
    expect(await usdc.balanceOf(liquidityProvider.address)).to.equal(amountToSeedWallets.sub(scaledAmountToLp));
    expect(await usdc.balanceOf(hubPool.address)).to.equal(scaledAmountToLp);

    // Redemption should work as normal, just scaled.
    await hubPool.connect(liquidityProvider).removeLiquidity(usdc.address, scaledAmountToLp.div(2), false);
    expect(await usdcLpToken.balanceOf(liquidityProvider.address)).to.equal(scaledAmountToLp.div(2));
    expect(await usdc.balanceOf(liquidityProvider.address)).to.equal(amountToSeedWallets.sub(scaledAmountToLp.div(2)));
    expect(await usdc.balanceOf(hubPool.address)).to.equal(scaledAmountToLp.div(2));
  });
});
