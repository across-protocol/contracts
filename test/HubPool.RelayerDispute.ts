import { expect } from "chai";
import { Contract } from "ethers";
import { ethers } from "hardhat";
import { parseAncillaryData } from "@uma/common";
import { SignerWithAddress, seedWallet } from "./utils";
import * as consts from "./constants";
import { hubPoolFixture, enableTokensForLP } from "./HubPool.Fixture";

let hubPool: Contract, weth: Contract, optimisticOracle: Contract;
let owner: SignerWithAddress, dataWorker: SignerWithAddress, liquidityProvider: SignerWithAddress;

describe("HubPool Relayer Refund Dispute", function () {
  beforeEach(async function () {
    [owner, dataWorker, liquidityProvider] = await ethers.getSigners();
    ({ weth, hubPool, optimisticOracle } = await hubPoolFixture());
    await enableTokensForLP(owner, hubPool, weth, [weth]);

    await seedWallet(dataWorker, [], weth, consts.bondAmount.add(consts.finalFee).mul(2));
    await seedWallet(liquidityProvider, [], weth, consts.amountToLp);
    await weth.connect(liquidityProvider).approve(hubPool.address, consts.amountToLp);
    await hubPool.connect(liquidityProvider).addLiquidity(weth.address, consts.amountToLp);
  });

  it("Dispute relayer refund correctly deletes the active request and enqueues a price request with the OO", async function () {
    await weth.connect(dataWorker).approve(hubPool.address, consts.bondAmount.mul(10));
    await hubPool
      .connect(dataWorker)
      .initiateRelayerRefund(
        consts.mockBundleEvaluationBlockNumbers,
        consts.mockPoolRebalanceLeafCount,
        consts.mockPoolRebalanceRoot,
        consts.mockDestinationDistributionRoot,
        consts.mockSlowRelayFulfillmentRoot
      );

    const preCallAncillaryData = await hubPool._getRefundProposalAncillaryData();

    await hubPool.connect(dataWorker).disputeRelayerRefund();

    // Data should be deleted from the contracts refundRequest struct.
    const refundRequest = await hubPool.refundRequest();
    expect(refundRequest.requestExpirationTimestamp).to.equal(0);
    expect(refundRequest.unclaimedPoolRebalanceLeafCount).to.equal(0);
    expect(refundRequest.poolRebalanceRoot).to.equal(consts.zeroBytes32);
    expect(refundRequest.destinationDistributionRoot).to.equal(consts.zeroBytes32);
    expect(refundRequest.claimedBitMap).to.equal(0); // no claims yet so everything should be marked at 0.
    expect(refundRequest.proposer).to.equal(consts.zeroAddress);
    expect(refundRequest.proposerBondRepaid).to.equal(false);

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
    expect("0x" + parsedAncillaryData?.destinationDistributionRoot).to.equal(consts.mockDestinationDistributionRoot);
    expect(parsedAncillaryData?.claimedBitMap).to.equal(0);
    expect(ethers.utils.getAddress("0x" + parsedAncillaryData?.proposer)).to.equal(dataWorker.address);
  });
  it("Can not dispute after proposal liveness", async function () {
    await weth.connect(dataWorker).approve(hubPool.address, consts.bondAmount.mul(10));
    await hubPool
      .connect(dataWorker)
      .initiateRelayerRefund(
        consts.mockBundleEvaluationBlockNumbers,
        consts.mockPoolRebalanceLeafCount,
        consts.mockPoolRebalanceRoot,
        consts.mockDestinationDistributionRoot,
        consts.mockSlowRelayFulfillmentRoot
      );

    await hubPool.setCurrentTime(Number(await hubPool.getCurrentTime()) + consts.refundProposalLiveness + 1);

    await expect(hubPool.connect(dataWorker).disputeRelayerRefund()).to.be.revertedWith("Request passed liveness");
  });
});
