import { expect } from "chai";
import { Contract } from "ethers";
import { ethers } from "hardhat";
import { SignerWithAddress, seedWallet } from "./utils";
import * as consts from "./constants";
import { hubPoolFixture } from "./HubPool.Fixture";

let hubPool: Contract, weth: Contract, dataWorker: SignerWithAddress;

describe("HubPool Relayer Refund Initialization", function () {
  beforeEach(async function () {
    [dataWorker] = await ethers.getSigners();
    ({ weth, hubPool } = await hubPoolFixture());
    await seedWallet(dataWorker, [], weth, consts.bondAmount.add(consts.finalFee).mul(2));
  });

  it("Initialization of a relay correctly stores data, emits events and pulls the bond", async function () {
    const expectedRequestExpirationTimestamp = Number(await hubPool.getCurrentTime()) + consts.refundProposalLiveness;
    await weth.connect(dataWorker).approve(hubPool.address, consts.bondAmount);
    const dataWorkerWethBalancerBefore = await weth.callStatic.balanceOf(dataWorker.address);

    await expect(
      hubPool
        .connect(dataWorker)
        .initiateRelayerRefund(
          consts.mockBundleEvaluationBlockNumbers,
          consts.mockPoolRebalanceLeafCount,
          consts.mockPoolRebalanceRoot,
          consts.mockDestinationDistributionRoot
        )
    )
      .to.emit(hubPool, "InitiateRefundRequested")
      .withArgs(
        expectedRequestExpirationTimestamp,
        consts.mockPoolRebalanceLeafCount,
        consts.mockBundleEvaluationBlockNumbers,
        consts.mockPoolRebalanceRoot,
        consts.mockDestinationDistributionRoot,
        dataWorker.address
      );
    // Balances of the hubPool should have incremented by the bond and the dataWorker should have decremented by the bond.
    expect(await weth.balanceOf(hubPool.address)).to.equal(consts.bondAmount);
    expect(await weth.balanceOf(dataWorker.address)).to.equal(dataWorkerWethBalancerBefore.sub(consts.bondAmount));

    const refundRequest = await hubPool.refundRequest();
    expect(refundRequest.requestExpirationTimestamp).to.equal(expectedRequestExpirationTimestamp);
    expect(refundRequest.unclaimedPoolRebalanceLeafCount).to.equal(consts.mockPoolRebalanceLeafCount);
    expect(refundRequest.poolRebalanceRoot).to.equal(consts.mockPoolRebalanceRoot);
    expect(refundRequest.destinationDistributionRoot).to.equal(consts.mockDestinationDistributionRoot);
    expect(refundRequest.claimedBitMap).to.equal(0); // no claims yet so everything should be marked at 0.
    expect(refundRequest.proposer).to.equal(dataWorker.address);
    expect(refundRequest.proposerBondRepaid).to.equal(false);

    // Can not re-initialize if the previous bundle has unclaimed leaves.
    await expect(
      hubPool
        .connect(dataWorker)
        .initiateRelayerRefund(
          consts.mockBundleEvaluationBlockNumbers,
          consts.mockPoolRebalanceLeafCount,
          consts.mockPoolRebalanceRoot,
          consts.mockDestinationDistributionRoot
        )
    ).to.be.revertedWith("Active request has unclaimed leafs");
  });
});
