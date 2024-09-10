import { expect, ethers, Contract, SignerWithAddress, seedWallet, toWei } from "../../utils/utils";
import * as consts from "./constants";
import { hubPoolFixture, enableTokensForLP } from "./fixtures/HubPool.Fixture";
import { constructSingleChainTree } from "./MerkleLib.utils";

let hubPool: Contract, weth: Contract, timer: Contract;
let owner: SignerWithAddress, dataWorker: SignerWithAddress, liquidityProvider: SignerWithAddress;

describe("HubPool Liquidity Provision Haircut", function () {
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

  it("Haircut can correctly offset exchange rate current to encapsulate lossed tokens", async function () {
    const { tokensSendToL2, leaves, tree } = await constructSingleChainTree(weth.address);

    await hubPool
      .connect(dataWorker)
      .proposeRootBundle([3117], 1, tree.getHexRoot(), consts.mockTreeRoot, consts.mockSlowRelayRoot);
    await timer.setCurrentTime(Number(await timer.getCurrentTime()) + consts.refundProposalLiveness + 1);
    await hubPool.connect(dataWorker).executeRootBundle(...Object.values(leaves[0]), tree.getHexProof(leaves[0]));

    // Exchange rate current right after the refund execution should be the amount deposited, grown by the 100 second
    // liveness period. Of the 10 ETH attributed to LPs, a total of 10*0.0000015*7201=0.108015 was attributed to LPs.
    // The exchange rate is therefore (1000+0.108015)/1000=1.000108015.
    expect(await hubPool.callStatic.exchangeRateCurrent(weth.address)).to.equal(toWei(1.000108015));

    // At this point if all LP tokens are attempted to be redeemed at the provided exchange rate the call should fail
    // as the hub pool is currently waiting for funds to come back over the canonical bridge. they are lent out.
    await expect(hubPool.connect(liquidityProvider).removeLiquidity(weth.address, consts.amountToLp, false)).to.be
      .reverted;

    // Now, consider that the funds sent over the bridge (tokensSendToL2) are actually lost due to the L2 breaking.
    // We now need to haircut the LPs be modifying the exchange rate current such that they get a commensurate
    // redemption rate against the lost funds.
    await hubPool.haircutReserves(weth.address, tokensSendToL2);
    await hubPool.sync(weth.address);

    // The exchange rate current should now factor in the loss of funds and should now be less than 1. Taking the amount
    // attributed to LPs in fees from the previous calculation and the 100 lost tokens, the exchangeRateCurrent should be:
    // (1000+0.108015-100)/1000=0.900108015.
    expect(await hubPool.callStatic.exchangeRateCurrent(weth.address)).to.equal(toWei(0.900108015));

    // Now, advance time such that all accumulated rewards are accumulated.
    await timer.setCurrentTime(Number(await timer.getCurrentTime()) + 10 * 24 * 60 * 60);
    await hubPool.exchangeRateCurrent(weth.address); // force state sync.
    expect((await hubPool.pooledTokens(weth.address)).undistributedLpFees).to.equal(0);

    // Exchange rate should now be the (LPAmount + fees - lostTokens) / LPTokenSupply = (1000+10-100)/1000=0.91
    expect(await hubPool.callStatic.exchangeRateCurrent(weth.address)).to.equal(toWei(0.91));
  });
});
