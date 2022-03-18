import { parseAncillaryData } from "@uma/common";
import { SignerWithAddress, seedWallet, expect, Contract, ethers } from "./utils";
import * as consts from "./constants";
import { hubPoolFixture, enableTokensForLP } from "./fixtures/HubPool.Fixture";

let hubPool: Contract, weth: Contract, optimisticOracle: Contract, store: Contract, mockOracle: Contract;
let owner: SignerWithAddress, dataWorker: SignerWithAddress, liquidityProvider: SignerWithAddress;

describe("HubPool Root Bundle Dispute", function () {
  beforeEach(async function () {
    [owner, dataWorker, liquidityProvider] = await ethers.getSigners();
    ({ weth, hubPool, optimisticOracle, store, mockOracle } = await hubPoolFixture());
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

    // Increment time to avoid any weirdness with the dispute occuring at the same time as the proposal.
    const proposalTime = await hubPool.getCurrentTime();
    await hubPool.connect(dataWorker).setCurrentTime(proposalTime.add(15));

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

    // HubPool should use `getRootBundleProposalAncillaryData()` return value as the ancillary data that it sends
    // to the oracle, and the oracle should stamp the hub pool's address.
    const priceRequestAddedEvent = (await mockOracle.queryFilter(mockOracle.filters.PriceRequestAdded()))[0].args;
    const priceProposalEvent = (await optimisticOracle.queryFilter(optimisticOracle.filters.ProposePrice()))[0].args;

    expect(priceProposalEvent?.requester).to.equal(hubPool.address);
    expect(priceProposalEvent?.identifier).to.equal(consts.identifier);
    expect(priceProposalEvent?.ancillaryData).to.equal("0x");

    const parsedAncillaryData = parseAncillaryData(priceRequestAddedEvent?.ancillaryData);
    expect(ethers.utils.getAddress("0x" + parsedAncillaryData?.ooRequester)).to.equal(hubPool.address);
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
  it("Setting final fee equal to bond triggers cancellation", async function () {
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

    // Setting the final fee < totalBond should fail this test
    await store.setFinalFee(weth.address, { rawValue: consts.totalBond });

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

    // No proposal should have been made.
    expect((await optimisticOracle.queryFilter(optimisticOracle.filters.ProposePrice())).length).to.equal(0);
  });

  it("Decrease in final fee just reallocates some of final fee to bond", async function () {
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

    const newFinalFee = consts.finalFee.div(2);
    const newBond = consts.totalBond.sub(newFinalFee);

    await store.setFinalFee(weth.address, { rawValue: newFinalFee });

    // Note: because the final fee is being halved, it just works out that the net transfer is bondAmount.
    await expect(() => hubPool.connect(dataWorker).disputeRootBundle()).to.changeTokenBalances(
      weth,
      [dataWorker, hubPool, optimisticOracle, store],
      [
        consts.totalBond.mul(-1),
        consts.totalBond.mul(-1),
        consts.totalBond.add(newBond.div(2)),
        newFinalFee.add(newBond.div(2)),
      ]
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

    // Proposal/DVM request should have been made.
    expect((await optimisticOracle.queryFilter(optimisticOracle.filters.ProposePrice())).length).to.equal(1);
  });
});
