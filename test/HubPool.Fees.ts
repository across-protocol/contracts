import { expect } from "chai";
import { Contract } from "ethers";
import { ethers } from "hardhat";
import { SignerWithAddress, toBNWei, seedWallet, toWei, createRandomBytes32 } from "./utils";
import * as consts from "./constants";
import { hubPoolFixture, enableTokensForLP } from "./HubPool.Fixture";
import { buildPoolRebalanceTree, buildPoolRebalanceLeafs } from "./MerkleLib.utils";

let hubPool: Contract, weth: Contract, timer: Contract;
let owner: SignerWithAddress, dataWorker: SignerWithAddress, liquidityProvider: SignerWithAddress;

async function constructSimpleTree() {
  const wethSendToL2 = toBNWei(100);
  const wethAttributeToLps = toBNWei(10);
  const leafs = buildPoolRebalanceLeafs(
    [consts.repaymentChainId], // repayment chain. In this test we only want to send one token to one chain.
    [weth], // l1Token. We will only be sending WETH and DAI to the associated repayment chain.
    [[wethAttributeToLps]], // bundleLpFees. Set to 1 ETH and 10 DAI respectively to attribute to the LPs.
    [[wethSendToL2]], // netSendAmounts. Set to 100 ETH and 1000 DAI as the amount to send from L1->L2.
    [[wethSendToL2]] // runningBalances. Set to 100 ETH and 1000 DAI.
  );
  const tree = await buildPoolRebalanceTree(leafs);

  return { wethSendToL2, wethAttributeToLps, leafs, tree };
}

describe("HubPool LP fees", function () {
  beforeEach(async function () {
    [owner, dataWorker, liquidityProvider] = await ethers.getSigners();
    ({ weth, hubPool, timer } = await hubPoolFixture());
    await seedWallet(dataWorker, [], weth, consts.bondAmount.add(consts.finalFee).mul(2));
    await seedWallet(liquidityProvider, [], weth, consts.amountToLp.mul(10));

    await enableTokensForLP(owner, hubPool, weth, [weth]);
    await weth.connect(liquidityProvider).approve(hubPool.address, consts.amountToLp);
    await hubPool.connect(liquidityProvider).addLiquidity(weth.address, consts.amountToLp);
    await weth.connect(dataWorker).approve(hubPool.address, consts.bondAmount.mul(10));
  });

  it("Fee tracking variables are correctly updated at the execution of a refund", async function () {
    // Before any execution happens liquidity trackers are set as expected.
    const pooledTokenInfoPreExecution = await hubPool.pooledTokens(weth.address);
    expect(pooledTokenInfoPreExecution.liquidReserves).to.eq(consts.amountToLp);
    expect(pooledTokenInfoPreExecution.utilizedReserves).to.eq(0);
    expect(pooledTokenInfoPreExecution.undistributedLpFees).to.eq(0);
    expect(pooledTokenInfoPreExecution.lastLpFeeUpdate).to.eq(await timer.getCurrentTime());
    expect(pooledTokenInfoPreExecution.isWeth).to.eq(true);

    const { wethSendToL2, wethAttributeToLps, leafs, tree } = await constructSimpleTree();

    await hubPool
      .connect(dataWorker)
      .initiateRelayerRefund([3117], 1, tree.getHexRoot(), consts.mockTreeRoot, consts.mockSlowRelayFulfillmentRoot);
    await timer.setCurrentTime(Number(await timer.getCurrentTime()) + consts.refundProposalLiveness);
    await hubPool.connect(dataWorker).executeRelayerRefund(leafs[0], tree.getHexProof(leafs[0]));

    // Validate the post execution values have updated as expected. Liquid reserves should be the original LPed amount
    // minus the amount sent to L2. Utilized reserves should be the amount sent to L2 plus the attribute to LPs.
    // Undistributed LP fees should be attribute to LPs.
    const pooledTokenInfoPostExecution = await hubPool.pooledTokens(weth.address);
    expect(pooledTokenInfoPostExecution.liquidReserves).to.eq(consts.amountToLp.sub(wethSendToL2));
    expect(pooledTokenInfoPostExecution.utilizedReserves).to.eq(wethSendToL2.add(wethAttributeToLps));
    expect(pooledTokenInfoPostExecution.undistributedLpFees).to.eq(wethAttributeToLps);
  });

  it("Exchange rate current correctly attributes fees over the smear period", async function () {
    // Fees are designed to be attributed over a period of time so they dont all arrive on L1 as soon as the bundle is
    // executed. We can validate that fees are correctly smeared by attributing some and then moving time forward and
    // validating that key variable shift as a function of time.
    const { leafs, tree } = await constructSimpleTree();

    // Exchange rate current before any fees are attributed execution should be 1.
    expect(await hubPool.callStatic.exchangeRateCurrent(weth.address)).to.eq(toWei(1));
    await hubPool.exchangeRateCurrent(weth.address);

    await hubPool
      .connect(dataWorker)
      .initiateRelayerRefund([3117], 1, tree.getHexRoot(), consts.mockTreeRoot, consts.mockSlowRelayFulfillmentRoot);
    await timer.setCurrentTime(Number(await timer.getCurrentTime()) + consts.refundProposalLiveness);
    await hubPool.connect(dataWorker).executeRelayerRefund(leafs[0], tree.getHexProof(leafs[0]));

    // Exchange rate current right after the refund execution should be the amount deposited, grown by the 100 second
    // liveness period. Of the 10 ETH attributed to LPs, a total of 10*0.0000015*100=0.0015 was attributed to LPs.
    // The exchange rate is therefore (1000+0.0015)/1000=1.0000015.
    expect((await hubPool.callStatic.exchangeRateCurrent(weth.address)).toString()).to.eq(toWei(1.0000015));

    // Validate the state variables are updated accordingly. In particular, undistributedLpFees should have decremented
    // by the amount allocated in the previous computation. This should be 10-0.0015=9.9985.
    await hubPool.exchangeRateCurrent(weth.address); // force state sync.
    expect((await hubPool.pooledTokens(weth.address)).undistributedLpFees).to.eq(toWei(9.9985));

    // Next, advance time 2 days. Compute the ETH attributed to LPs by multiplying the original amount allocated(10),
    // minus the previous computation amount(0.0015) by the smear rate, by the duration to get the second periods
    // allocation of(10 - 0.0015) * 0.0000015 * (172800)=2.5916112.The exchange rate should be The sum of the
    // liquidity provided and the fees added in both periods as (1000+0.0015+2.5916112)/1000=1.0025931112.
    await timer.setCurrentTime(Number(await timer.getCurrentTime()) + 2 * 24 * 60 * 60);
    expect((await hubPool.callStatic.exchangeRateCurrent(weth.address)).toString()).to.eq(toWei(1.0025931112));

    // Again, we can validate that the undistributedLpFees have been updated accordingly. This should be set to the
    // original amount (10) minus the two sets of attributed LP fees as 10-0.0015-2.5916112=7.4068888.
    await hubPool.exchangeRateCurrent(weth.address); // force state sync.
    expect((await hubPool.pooledTokens(weth.address)).undistributedLpFees).to.eq(toWei(7.4068888));

    // Finally, advance time past the end of the smear period by moving forward 10 days. At this point all LP fees
    // should be attributed such that undistributedLpFees=0 and the exchange rate should simply be (1000+10)/1000=1.01.
    await timer.setCurrentTime(Number(await timer.getCurrentTime()) + 10 * 24 * 60 * 60);
    expect((await hubPool.callStatic.exchangeRateCurrent(weth.address)).toString()).to.eq(toWei(1.01));
    await hubPool.exchangeRateCurrent(weth.address); // force state sync.
    expect((await hubPool.pooledTokens(weth.address)).undistributedLpFees).to.eq(toWei(0));
  });
});
