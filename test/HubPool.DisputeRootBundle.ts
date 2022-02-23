import { parseAncillaryData } from "@uma/common";
import { SignerWithAddress, seedWallet, expect, Contract, ethers } from "./utils";
import * as consts from "./constants";
import { hubPoolFixture, enableTokensForLP } from "./HubPool.Fixture";

let hubPool: Contract, weth: Contract, optimisticOracle: Contract;
let owner: SignerWithAddress, dataWorker: SignerWithAddress, liquidityProvider: SignerWithAddress;

describe("HubPool Root Bundle Dispute", function () {
  beforeEach(async function () {
    [owner, dataWorker, liquidityProvider] = await ethers.getSigners();
    ({ weth, hubPool, optimisticOracle } = await hubPoolFixture());
    await enableTokensForLP(owner, hubPool, weth, [weth]);

    await seedWallet(dataWorker, [], weth, consts.totalBond.mul(2));
    await seedWallet(liquidityProvider, [], weth, consts.amountToLp);
    await weth.connect(liquidityProvider).approve(hubPool.address, consts.amountToLp);
    await hubPool.connect(liquidityProvider).addLiquidity(weth.address, consts.amountToLp);
  });

  it("Dispute root bundle correctly deletes the active proposal and enqueues a price request with the OO", async function () {
    await weth.connect(dataWorker).approve(hubPool.address, consts.totalBond.mul(2));
    await hubPool
      .connect(dataWorker)
      .proposeRootBundle(
        consts.mockBundleEvaluationBlockNumbers,
        consts.mockPoolRebalanceLeafCount,
        consts.mockPoolRebalanceRoot,
        consts.mockRelayerRefundRoot,
        consts.mockSlowRelayFulfillmentRoot
      );

    const preCallAncillaryData = await hubPool.getRootBundleProposalAncillaryData();

    await hubPool.connect(dataWorker).disputeRootBundle();

    // Data should be deleted from the contracts refundRequest struct.
    const rootBundle = await hubPool.rootBundleProposal();
    expect(rootBundle.requestExpirationTimestamp).to.equal(0);
    expect(rootBundle.unclaimedPoolRebalanceLeafCount).to.equal(0);
    expect(rootBundle.poolRebalanceRoot).to.equal(consts.zeroBytes32);
    expect(rootBundle.relayerRefundRoot).to.equal(consts.zeroBytes32);
    expect(rootBundle.slowRelayFulfillmentRoot).to.equal(consts.zeroBytes32);
    expect(rootBundle.claimedBitMap).to.equal(0); // no claims yet so everything should be marked at 0.
    expect(rootBundle.proposer).to.equal(consts.zeroAddress);
    expect(rootBundle.proposerBondRepaid).to.equal(false);

    const priceProposalEvent = (await optimisticOracle.queryFilter(optimisticOracle.filters.ProposePrice()))[0].args;

    expect(priceProposalEvent?.requester).to.equal(hubPool.address);
    expect(priceProposalEvent?.identifier).to.equal(consts.identifier);
    expect(priceProposalEvent?.ancillaryData).to.equal(preCallAncillaryData);

    const parsedAncillaryData = parseAncillaryData(priceProposalEvent?.ancillaryData);
    expect(parsedAncillaryData?.requestExpirationTimestamp).to.equal(
      Number(await hubPool.getCurrentTime()) + consts.refundProposalLiveness
    );
    expect(parsedAncillaryData?.unclaimedPoolRebalanceLeafCount).to.equal(consts.mockPoolRebalanceLeafCount);
    expect("0x" + parsedAncillaryData?.poolRebalanceRoot).to.equal(consts.mockPoolRebalanceRoot);
    expect("0x" + parsedAncillaryData?.relayerRefundRoot).to.equal(consts.mockRelayerRefundRoot);
    expect("0x" + parsedAncillaryData?.slowRelayFulfillmentRoot).to.equal(consts.mockSlowRelayFulfillmentRoot);
    expect(parsedAncillaryData?.claimedBitMap).to.equal(0);
    expect(ethers.utils.getAddress("0x" + parsedAncillaryData?.proposer)).to.equal(dataWorker.address);
  });
  it("Can not dispute after proposal liveness", async function () {
    await weth.connect(dataWorker).approve(hubPool.address, consts.totalBond.mul(2));
    await hubPool
      .connect(dataWorker)
      .proposeRootBundle(
        consts.mockBundleEvaluationBlockNumbers,
        consts.mockPoolRebalanceLeafCount,
        consts.mockPoolRebalanceRoot,
        consts.mockRelayerRefundRoot,
        consts.mockSlowRelayFulfillmentRoot
      );

    await hubPool.setCurrentTime(Number(await hubPool.getCurrentTime()) + consts.refundProposalLiveness + 1);

    await expect(hubPool.connect(dataWorker).disputeRootBundle()).to.be.revertedWith("Request passed liveness");
  });
});
