import { expect } from "chai";
import { Contract } from "ethers";
import { ethers } from "hardhat";

import { SignerWithAddress, createRandomBytes32, seedWallet } from "./utils";
import { bondAmount, refundProposalLiveness, zeroAddress, zeroBytes32, amountToLp } from "./constants";
import { deployHubPoolTestHelperContracts } from "./HubPool.Fixture";
import { deployUmaEcosystemContracts } from "./Uma.Fixture";

let hubPool: Contract, weth: Contract, finder: Contract, timer: Contract, optimisticOracle: Contract;
let owner: SignerWithAddress, dataWorker: SignerWithAddress;

const mockBundleEvaluationBlockNumbers = [1, 2, 3];
const mockPoolRebalanceLeafCount = 5;
const mockPoolRebalanceRoot = createRandomBytes32();
const mockDestinationDistributionRoot = createRandomBytes32();

describe("HubPool Relayer Refund", function () {
  beforeEach(async function () {
    [owner, dataWorker] = await ethers.getSigners();
    ({ finder, timer, optimisticOracle } = await deployUmaEcosystemContracts(owner));
    ({ weth, hubPool } = await deployHubPoolTestHelperContracts(owner, finder, timer));
    await seedWallet(owner, [], weth, bondAmount);
    await seedWallet(dataWorker, [], weth, bondAmount.mul(2));
  });

  it("Initialization of a relay correctly stores data, emits events and pulls the bond", async function () {
    const expectedRequestExpirationTimestamp = Number(await hubPool.getCurrentTime()) + refundProposalLiveness;
    await weth.connect(dataWorker).approve(hubPool.address, bondAmount);
    await expect(
      hubPool
        .connect(dataWorker)
        .initiateRelayerRefund(
          mockBundleEvaluationBlockNumbers,
          mockPoolRebalanceLeafCount,
          mockPoolRebalanceRoot,
          mockDestinationDistributionRoot
        )
    )
      .to.emit(hubPool, "InitiateRefundRequested")
      .withArgs(
        expectedRequestExpirationTimestamp,
        mockPoolRebalanceLeafCount,
        mockBundleEvaluationBlockNumbers,
        mockPoolRebalanceRoot,
        mockDestinationDistributionRoot,
        dataWorker.address
      );
    // Balances of the hubPool should have incremented by the bond and the dataWorker should have decremented by the bond.
    expect(await weth.balanceOf(hubPool.address)).to.equal(bondAmount);
    expect(await weth.balanceOf(dataWorker.address)).to.equal(0);

    const refundRequest = await hubPool.refundRequest();
    expect(refundRequest.requestExpirationTimestamp).to.equal(expectedRequestExpirationTimestamp);
    expect(refundRequest.unclaimedPoolRebalanceLeafs).to.equal(mockPoolRebalanceLeafCount);
    expect(refundRequest.poolRebalanceRoot).to.equal(mockPoolRebalanceRoot);
    expect(refundRequest.destinationDistributionRoot).to.equal(mockDestinationDistributionRoot);
    expect(refundRequest.claimedBitMap).to.equal(0); // no claims yet so everything should be marked at 0.
    expect(refundRequest.proposer).to.equal(dataWorker.address);
    expect(refundRequest.proposerBondRepaid).to.equal(false);

    // Can not re-initialize if the previous bundle has unclaimed leaves.
    await expect(
      hubPool
        .connect(dataWorker)
        .initiateRelayerRefund(
          mockBundleEvaluationBlockNumbers,
          mockPoolRebalanceLeafCount,
          mockPoolRebalanceRoot,
          mockDestinationDistributionRoot
        )
    ).to.be.revertedWith("Last bundle has unclaimed leafs");
  });
  it("Dispute relayer refund correctly deletes the active request and enqueues a price request with the OO", async function () {
    await hubPool.addLiquidity(weth.address, amountToLp);
    await weth.connect(dataWorker).approve(hubPool.address, bondAmount.mul(2));
    await hubPool
      .connect(dataWorker)
      .initiateRelayerRefund(
        mockBundleEvaluationBlockNumbers,
        mockPoolRebalanceLeafCount,
        mockPoolRebalanceRoot,
        mockDestinationDistributionRoot
      );

    await hubPool.connect(dataWorker).disputeRelayerRefund();
    // await expect(hubPool.connect(dataWorker).disputeRelayerRefund())
    //   .to.emit(hubPool, "RelayerRefundDisputed")
    //   .withArgs(owner.address);

    // console.log("OO LOGS",await optimisticOracle.filters.)

    // Data should be deleted from the contracts refundRequest struct.
    const refundRequest = await hubPool.refundRequest();
    expect(refundRequest.requestExpirationTimestamp).to.equal(0);
    expect(refundRequest.unclaimedPoolRebalanceLeafs).to.equal(0);
    expect(refundRequest.poolRebalanceRoot).to.equal(zeroBytes32);
    expect(refundRequest.destinationDistributionRoot).to.equal(zeroBytes32);
    expect(refundRequest.claimedBitMap).to.equal(0); // no claims yet so everything should be marked at 0.
    expect(refundRequest.proposer).to.equal(zeroAddress);
    expect(refundRequest.proposerBondRepaid).to.equal(false);
  });
});
