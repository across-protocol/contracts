"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
const utils_1 = require("./utils");
const HubPool_Fixture_1 = require("./fixtures/HubPool.Fixture");
const constants_1 = require("./constants");
let hubPool, weth, usdc, dai;
let wethLpToken, usdcLpToken, daiLpToken;
let owner, liquidityProvider, other;
describe("HubPool Liquidity Provision", function () {
  beforeEach(async function () {
    [owner, liquidityProvider, other] = await utils_1.ethers.getSigners();
    ({ weth, usdc, dai, hubPool } = await (0, HubPool_Fixture_1.hubPoolFixture)());
    [wethLpToken, usdcLpToken, daiLpToken] = await (0, HubPool_Fixture_1.enableTokensForLP)(owner, hubPool, weth, [
      weth,
      usdc,
      dai,
    ]);
    // mint some fresh tokens and deposit ETH for weth for the liquidity provider.
    await (0, utils_1.seedWallet)(liquidityProvider, [usdc, dai], weth, constants_1.amountToSeedWallets);
  });
  it("Adding ER20 liquidity correctly pulls tokens and mints LP tokens", async function () {
    const daiLpToken = await (
      await (0, utils_1.getContractFactory)("ExpandedERC20", owner)
    ).attach((await hubPool.callStatic.pooledTokens(dai.address)).lpToken);
    // Balances of collateral before should equal the seed amount and there should be 0 outstanding LP tokens.
    (0, utils_1.expect)(await dai.balanceOf(liquidityProvider.address)).to.equal(constants_1.amountToSeedWallets);
    (0, utils_1.expect)(await daiLpToken.balanceOf(liquidityProvider.address)).to.equal(0);
    await dai.connect(liquidityProvider).approve(hubPool.address, constants_1.amountToLp);
    await hubPool.connect(liquidityProvider).addLiquidity(dai.address, constants_1.amountToLp);
    // The balance of the collateral should be equal to the original amount minus the LPed amount. The balance of LP
    // tokens should be equal to the amount of LP tokens divided by the exchange rate current. This rate starts at 1e18,
    // so this should equal the amount minted.
    (0, utils_1.expect)(await dai.balanceOf(liquidityProvider.address)).to.equal(
      constants_1.amountToSeedWallets.sub(constants_1.amountToLp)
    );
    (0, utils_1.expect)(await daiLpToken.balanceOf(liquidityProvider.address)).to.equal(constants_1.amountToLp);
    (0, utils_1.expect)(await daiLpToken.totalSupply()).to.equal(constants_1.amountToLp);
  });
  it("Removing ER20 liquidity burns LP tokens and returns collateral", async function () {
    await dai.connect(liquidityProvider).approve(hubPool.address, constants_1.amountToLp);
    await hubPool.connect(liquidityProvider).addLiquidity(dai.address, constants_1.amountToLp);
    // Next, try remove half the liquidity. This should modify the balances, as expected.
    await hubPool.connect(liquidityProvider).removeLiquidity(dai.address, constants_1.amountToLp.div(2), false);
    (0, utils_1.expect)(await dai.balanceOf(liquidityProvider.address)).to.equal(
      constants_1.amountToSeedWallets.sub(constants_1.amountToLp.div(2))
    );
    (0, utils_1.expect)(await daiLpToken.balanceOf(liquidityProvider.address)).to.equal(constants_1.amountToLp.div(2));
    (0, utils_1.expect)(await daiLpToken.totalSupply()).to.equal(constants_1.amountToLp.div(2));
    // Removing more than the total balance of LP tokens should throw.
    await (0, utils_1.expect)(hubPool.connect(other).removeLiquidity(dai.address, constants_1.amountToLp, false)).to.be
      .reverted;
    // Cant try receive ETH if the token is pool token is not WETH. Try redeem 1/3 of the original amount added. This is
    // less than the total amount the wallet has left (since we removed half the amount before).
    await (0, utils_1.expect)(hubPool.connect(other).removeLiquidity(dai.address, constants_1.amountToLp.div(3), true))
      .to.be.reverted;
    // Can remove the remaining LP tokens for a balance of 0.
    await hubPool.connect(liquidityProvider).removeLiquidity(dai.address, constants_1.amountToLp.div(2), false);
    (0, utils_1.expect)(await dai.balanceOf(liquidityProvider.address)).to.equal(constants_1.amountToSeedWallets); // back to starting balance.
    (0, utils_1.expect)(await daiLpToken.balanceOf(liquidityProvider.address)).to.equal(0); // All LP tokens burnt.
    (0, utils_1.expect)(await daiLpToken.totalSupply()).to.equal(0);
  });
  it("Adding ETH liquidity correctly wraps to WETH and mints LP tokens", async function () {
    // Depositor can send WETH, if they have. Explicitly set the value to 0 to ensure we dont send any eth with the tx.
    await weth.connect(liquidityProvider).approve(hubPool.address, constants_1.amountToLp);
    await hubPool.connect(liquidityProvider).addLiquidity(weth.address, constants_1.amountToLp, { value: 0 });
    (0, utils_1.expect)(await weth.balanceOf(liquidityProvider.address)).to.equal(
      constants_1.amountToSeedWallets.sub(constants_1.amountToLp)
    );
    (0, utils_1.expect)(await wethLpToken.balanceOf(liquidityProvider.address)).to.equal(constants_1.amountToLp);
    // Next, try depositing ETH with the transaction. No WETH should be sent. The ETH send with the TX should be
    // wrapped for the user and LP tokens minted. Send the deposit and check the ether balance changes as expected.
    await (0, utils_1.expect)(() =>
      hubPool
        .connect(liquidityProvider)
        .addLiquidity(weth.address, constants_1.amountToLp, { value: constants_1.amountToLp })
    ).to.changeEtherBalance(weth, constants_1.amountToLp); // WETH's Ether balance should increase by the amount LPed.
    // The weth Token balance should have stayed the same as no weth was spent.
    (0, utils_1.expect)(await weth.balanceOf(liquidityProvider.address)).to.equal(
      constants_1.amountToSeedWallets.sub(constants_1.amountToLp)
    );
    // However, the WETH LP token should have increase by the amount of LP tokens minted, as 2 x amountToLp.
    (0, utils_1.expect)(await wethLpToken.balanceOf(liquidityProvider.address)).to.equal(constants_1.amountToLp.mul(2));
    // Equally, the total WETH supply should have increased by the amount of LP tokens minted as they were deposited.
    (0, utils_1.expect)(await wethLpToken.totalSupply()).to.equal(constants_1.amountToLp.mul(2));
    (0, utils_1.expect)(await weth.totalSupply()).to.equal(constants_1.amountToLp.add(constants_1.amountToSeedWallets));
  });
  it("Removing ETH liquidity can send back WETH or ETH depending on the users choice", async function () {
    await weth.connect(liquidityProvider).approve(hubPool.address, constants_1.amountToLp);
    await hubPool.connect(liquidityProvider).addLiquidity(weth.address, constants_1.amountToLp);
    // Remove half the liquidity as WETH (set sendETH = false). This should modify the weth bal and not the eth bal.
    await (0, utils_1.expect)(() =>
      hubPool.connect(liquidityProvider).removeLiquidity(weth.address, constants_1.amountToLp.div(2), false)
    ).to.changeEtherBalance(liquidityProvider, 0);
    (0, utils_1.expect)(await weth.balanceOf(liquidityProvider.address)).to.equal(
      constants_1.amountToSeedWallets.sub(constants_1.amountToLp.div(2))
    ); // WETH balance should increase by the amount removed.
    // Next, remove half the liquidity as ETH (set sendETH = true). This should modify the eth bal but not the weth bal.
    await (0, utils_1.expect)(() =>
      hubPool.connect(liquidityProvider).removeLiquidity(weth.address, constants_1.amountToLp.div(2), true)
    ).to.changeEtherBalance(liquidityProvider, constants_1.amountToLp.div(2)); // There should be ETH transferred, not WETH.
    (0, utils_1.expect)(await weth.balanceOf(liquidityProvider.address)).to.equal(
      constants_1.amountToSeedWallets.sub(constants_1.amountToLp.div(2))
    ); // weth balance stayed the same.
    // There should be no LP tokens left outstanding:
    (0, utils_1.expect)(await wethLpToken.balanceOf(liquidityProvider.address)).to.equal(0);
  });
  it("Adding and removing non-18 decimal collateral mints the commensurate amount of LP tokens", async function () {
    // USDC is 6 decimal places. Scale the amountToLp back to a normal number then up by 6 decimal places to get a 1e6
    // scaled number. i.e amountToLp is 1000 so this number will be 1e6.
    const scaledAmountToLp = (0, utils_1.toBN)((0, utils_1.fromWei)(constants_1.amountToLp)).mul(1e6); // USDC is 6 decimal places.
    await usdc.connect(liquidityProvider).approve(hubPool.address, constants_1.amountToLp);
    await hubPool.connect(liquidityProvider).addLiquidity(usdc.address, scaledAmountToLp);
    // Check the balances are correct.
    (0, utils_1.expect)(await usdcLpToken.balanceOf(liquidityProvider.address)).to.equal(scaledAmountToLp);
    (0, utils_1.expect)(await usdc.balanceOf(liquidityProvider.address)).to.equal(
      constants_1.amountToSeedWallets.sub(scaledAmountToLp)
    );
    (0, utils_1.expect)(await usdc.balanceOf(hubPool.address)).to.equal(scaledAmountToLp);
    // Redemption should work as normal, just scaled.
    await hubPool.connect(liquidityProvider).removeLiquidity(usdc.address, scaledAmountToLp.div(2), false);
    (0, utils_1.expect)(await usdcLpToken.balanceOf(liquidityProvider.address)).to.equal(scaledAmountToLp.div(2));
    (0, utils_1.expect)(await usdc.balanceOf(liquidityProvider.address)).to.equal(
      constants_1.amountToSeedWallets.sub(scaledAmountToLp.div(2))
    );
    (0, utils_1.expect)(await usdc.balanceOf(hubPool.address)).to.equal(scaledAmountToLp.div(2));
  });
});
