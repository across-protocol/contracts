import { expect } from "chai";
import { Contract } from "ethers";

import { ethers } from "hardhat";
import { ZERO_ADDRESS } from "@uma/common";
import { getContractFactory, SignerWithAddress, createRandomBytes32, seedWallet } from "./utils";
import { depositDestinationChainId, bondAmount, refundProposalLiveness } from "./constants";
import { hubPoolFixture } from "./HubPool.Fixture";

let hubPool: Contract, weth: Contract, usdc: Contract;
let owner: SignerWithAddress, dataWorker: SignerWithAddress;

describe("HubPool Relayer Refund", function () {
  before(async function () {
    [owner, dataWorker] = await ethers.getSigners();
    ({ weth, hubPool, usdc } = await hubPoolFixture());
    await seedWallet(dataWorker, [], weth, bondAmount);
  });

  it("Initialization of a relay correctly stores data, emits events and pulls the bond", async function () {
    const bundleEvaluationBlockNumbers = [1, 2, 3];
    const poolRebalanceLeafCount = 5;
    const poolRebalanceProof = createRandomBytes32();
    const destinationDistributionProof = createRandomBytes32();

    const expectedRequestExpirationTimestamp = Number(await hubPool.getCurrentTime()) + refundProposalLiveness;
    await weth.connect(dataWorker).approve(hubPool.address, bondAmount);
    await expect(
      hubPool
        .connect(dataWorker)
        .initiateRelayerRefund(
          bundleEvaluationBlockNumbers,
          poolRebalanceLeafCount,
          poolRebalanceProof,
          destinationDistributionProof
        )
    )
      .to.emit(hubPool, "InitiateRefundRequested")
      .withArgs(
        0,
        expectedRequestExpirationTimestamp,
        poolRebalanceLeafCount,
        bundleEvaluationBlockNumbers,
        poolRebalanceProof,
        destinationDistributionProof,
        dataWorker.address
      );
    // Balances of the hubPool should have incremented by the bond and the dataWorker should have decremented by the bond.
    expect(await weth.balanceOf(hubPool.address)).to.equal(bondAmount);
    expect(await weth.balanceOf(dataWorker.address)).to.equal(0);

    // Can not re-initialize if the previous bundle has unclaimed leaves.
    await expect(
      hubPool
        .connect(dataWorker)
        .initiateRelayerRefund(
          bundleEvaluationBlockNumbers,
          poolRebalanceLeafCount,
          poolRebalanceProof,
          destinationDistributionProof
        )
    ).to.be.revertedWith("Last bundle has unclaimed leafs");
  });
});
