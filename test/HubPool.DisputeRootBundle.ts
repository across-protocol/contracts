import { parseAncillaryData } from "@uma/common";
import { SignerWithAddress, seedWallet, expect, Contract, ethers, toWei } from "./utils";
import * as consts from "./constants";
import { hubPoolFixture, enableTokensForLP } from "./HubPool.Fixture";

let hubPool: Contract, weth: Contract, optimisticOracle: Contract, store: Contract;
let owner: SignerWithAddress, dataWorker: SignerWithAddress, liquidityProvider: SignerWithAddress;

describe("HubPool Root Bundle Dispute", function () {
  beforeEach(async function () {
    [owner, dataWorker, liquidityProvider] = await ethers.getSigners();
    ({ weth, hubPool, optimisticOracle, store } = await hubPoolFixture());
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
        consts.mockSlowRelayRoot
      );

    const preCallAncillaryData = await hubPool.getRootBundleProposalAncillaryData();

    await hubPool.connect(dataWorker).disputeRootBundle();

    // Data should be deleted from the contracts refundRequest struct.
    const rootBundle = await hubPool.rootBundleProposal();
    expect(rootBundle.requestExpirationTimestamp).to.equal(0);
    expect(rootBundle.unclaimedPoolRebalanceLeafCount).to.equal(0);
    expect(rootBundle.poolRebalanceRoot).to.equal(consts.zeroBytes32);
    expect(rootBundle.relayerRefundRoot).to.equal(consts.zeroBytes32);
    expect(rootBundle.slowRelayRoot).to.equal(consts.zeroBytes32);
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
    expect("0x" + parsedAncillaryData?.slowRelayRoot).to.equal(consts.mockSlowRelayRoot);
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
        consts.mockSlowRelayRoot
      );

    await hubPool.setCurrentTime(Number(await hubPool.getCurrentTime()) + consts.refundProposalLiveness + 1);

    await expect(hubPool.connect(dataWorker).disputeRootBundle()).to.be.revertedWith("Request passed liveness");
  });
  it("Increase in final fee triggers cancellation", async function () {
    await weth.connect(dataWorker).approve(hubPool.address, consts.totalBond.mul(2));
    await hubPool
      .connect(dataWorker)
      .proposeRootBundle(
        consts.mockBundleEvaluationBlockNumbers,
        consts.mockPoolRebalanceLeafCount,
        consts.mockPoolRebalanceRoot,
        consts.mockRelayerRefundRoot,
        consts.mockSlowRelayRoot
      );

    await store.setFinalFee(weth.address, { rawValue: consts.finalFee.mul(10) });

    await expect(() => hubPool.connect(dataWorker).disputeRootBundle()).to.changeTokenBalances(
      weth,
      [dataWorker, hubPool],
      [consts.totalBond, consts.totalBond.mul(-1)]
    );

    // Data should be deleted from the contracts refundRequest struct.
    const rootBundle = await hubPool.rootBundleProposal();
    expect(rootBundle.requestExpirationTimestamp).to.equal(0);
    expect(rootBundle.unclaimedPoolRebalanceLeafCount).to.equal(0);
    expect(rootBundle.poolRebalanceRoot).to.equal(consts.zeroBytes32);
    expect(rootBundle.relayerRefundRoot).to.equal(consts.zeroBytes32);
    expect(rootBundle.slowRelayRoot).to.equal(consts.zeroBytes32);
    expect(rootBundle.claimedBitMap).to.equal(0); // no claims yet so everything should be marked at 0.
    expect(rootBundle.proposer).to.equal(consts.zeroAddress);
    expect(rootBundle.proposerBondRepaid).to.equal(false);

    expect((await optimisticOracle.queryFilter(optimisticOracle.filters.ProposePrice())).length).to.equal(0);
  });

  it("Decrease in final fee triggers proposer refund", async function () {
    await weth.connect(dataWorker).approve(hubPool.address, consts.totalBond.mul(2));
    await hubPool
      .connect(dataWorker)
      .proposeRootBundle(
        consts.mockBundleEvaluationBlockNumbers,
        consts.mockPoolRebalanceLeafCount,
        consts.mockPoolRebalanceRoot,
        consts.mockRelayerRefundRoot,
        consts.mockSlowRelayRoot
      );

    await store.setFinalFee(weth.address, { rawValue: consts.finalFee.div(2) });

    console.log(consts.totalBond.toString());
    console.log(consts.finalFee.toString());
    console.log(consts.bondAmount.toString());

    // Note: because the final fee is being halved, it just works out that the net transfer is bondAmount.
    await expect(() => hubPool.connect(dataWorker).disputeRootBundle()).to.changeTokenBalances(
      weth,
      [dataWorker, hubPool, optimisticOracle, store],
      [consts.bondAmount.mul(-1), consts.totalBond.mul(-1), consts.bondAmount.mul(2), consts.finalFee]
    );

    // Data should be deleted from the contracts refundRequest struct.
    const rootBundle = await hubPool.rootBundleProposal();
    expect(rootBundle.requestExpirationTimestamp).to.equal(0);
    expect(rootBundle.unclaimedPoolRebalanceLeafCount).to.equal(0);
    expect(rootBundle.poolRebalanceRoot).to.equal(consts.zeroBytes32);
    expect(rootBundle.relayerRefundRoot).to.equal(consts.zeroBytes32);
    expect(rootBundle.slowRelayRoot).to.equal(consts.zeroBytes32);
    expect(rootBundle.claimedBitMap).to.equal(0); // no claims yet so everything should be marked at 0.
    expect(rootBundle.proposer).to.equal(consts.zeroAddress);
    expect(rootBundle.proposerBondRepaid).to.equal(false);

    expect((await optimisticOracle.queryFilter(optimisticOracle.filters.ProposePrice())).length).to.equal(0);
  });
});
