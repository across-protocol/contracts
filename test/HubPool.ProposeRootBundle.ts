import { SignerWithAddress, seedWallet, expect, Contract, ethers } from "./utils";
import * as consts from "./constants";
import { hubPoolFixture } from "./fixtures/HubPool.Fixture";

let hubPool: Contract, weth: Contract, dataWorker: SignerWithAddress, owner: SignerWithAddress;

describe("HubPool Root Bundle Proposal", function () {
  beforeEach(async function () {
    [owner, dataWorker] = await ethers.getSigners();
    ({ weth, hubPool } = await hubPoolFixture());
    await seedWallet(dataWorker, [], weth, consts.totalBond);
  });

  it("Proposal of root bundle correctly stores data, emits events and pulls the bond", async function () {
    const expectedchallengePeriodEndTimestamp = Number(await hubPool.getCurrentTime()) + consts.refundProposalLiveness;
    await weth.connect(dataWorker).approve(hubPool.address, consts.totalBond);
    const dataWorkerWethBalancerBefore = await weth.callStatic.balanceOf(dataWorker.address);

    await expect(
      hubPool
        .connect(dataWorker)
        .proposeRootBundle(
          consts.mockBundleEvaluationBlockNumbers,
          consts.mockPoolRebalanceLeafCount,
          consts.mockPoolRebalanceRoot,
          consts.mockRelayerRefundRoot,
          consts.mockSlowRelayRoot
        )
    )
      .to.emit(hubPool, "ProposeRootBundle")
      .withArgs(
        expectedchallengePeriodEndTimestamp,
        consts.mockPoolRebalanceLeafCount,
        consts.mockBundleEvaluationBlockNumbers,
        consts.mockPoolRebalanceRoot,
        consts.mockRelayerRefundRoot,
        consts.mockSlowRelayRoot,
        dataWorker.address
      );
    // Balances of the hubPool should have incremented by the bond and the dataWorker should have decremented by the bond.
    expect(await weth.balanceOf(hubPool.address)).to.equal(consts.totalBond);
    expect(await weth.balanceOf(dataWorker.address)).to.equal(dataWorkerWethBalancerBefore.sub(consts.totalBond));

    const rootBundle = await hubPool.rootBundleProposal();
    expect(rootBundle.challengePeriodEndTimestamp).to.equal(expectedchallengePeriodEndTimestamp);
    expect(rootBundle.unclaimedPoolRebalanceLeafCount).to.equal(consts.mockPoolRebalanceLeafCount);
    expect(rootBundle.poolRebalanceRoot).to.equal(consts.mockPoolRebalanceRoot);
    expect(rootBundle.relayerRefundRoot).to.equal(consts.mockRelayerRefundRoot);
    expect(rootBundle.claimedBitMap).to.equal(0); // no claims yet so everything should be marked at 0.
    expect(rootBundle.proposer).to.equal(dataWorker.address);

    // Can not re-initialize if the previous bundle has unclaimed leaves.
    await expect(
      hubPool
        .connect(dataWorker)
        .proposeRootBundle(
          consts.mockBundleEvaluationBlockNumbers,
          consts.mockPoolRebalanceLeafCount,
          consts.mockPoolRebalanceRoot,
          consts.mockRelayerRefundRoot,
          consts.mockSlowRelayRoot
        )
    ).to.be.revertedWith("Proposal has unclaimed leaves");
  });

  it("Cannot propose while paused", async function () {
    await seedWallet(owner, [], weth, consts.totalBond);
    await weth.approve(hubPool.address, consts.totalBond);
    await hubPool.connect(owner).setPaused(true);
    await expect(
      hubPool.proposeRootBundle([1, 2, 3], 5, consts.mockTreeRoot, consts.mockTreeRoot, consts.mockSlowRelayRoot)
    ).to.be.revertedWith("Proposal process has been paused");
  });
});
