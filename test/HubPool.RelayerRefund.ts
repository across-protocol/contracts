import { expect } from "chai";
import { Contract } from "ethers";

import { ethers } from "hardhat";
import { ZERO_ADDRESS } from "@uma/common";
import { getContractFactory, SignerWithAddress, createRandomBytes32, seedWallet } from "./utils";
import { depositDestinationChainId, bondAmount } from "./constants";
import { deployHubPoolTestHelperContracts } from "./HubPool.Fixture";

let hubPool: Contract, weth: Contract, usdc: Contract;
let owner: SignerWithAddress, dataWorker: SignerWithAddress;

describe("HubPool Relayer Refund", function () {
  before(async function () {
    [owner, dataWorker] = await ethers.getSigners();
    ({ weth, hubPool, usdc } = await deployHubPoolTestHelperContracts(owner));
    await seedWallet(dataWorker, [], weth, bondAmount);
  });

  it("Initialization of a relay correctly stores data, emits events and pulls the bond", async function () {
    const bundleEvaluationBlockNumbers = [1, 2, 3];
    const poolRebalanceProof = createRandomBytes32();
    const destinationDistributionProof = createRandomBytes32();

    await weth.connect(dataWorker).approve(hubPool.address, bondAmount);
    await expect(
      hubPool
        .connect(dataWorker)
        .initiateRelayerRefund(bundleEvaluationBlockNumbers, poolRebalanceProof, destinationDistributionProof)
    )
      .to.emit(hubPool, "RelayerRefundRequested")
      .withArgs(0, bundleEvaluationBlockNumbers, poolRebalanceProof, destinationDistributionProof, dataWorker.address);
    // Balances of the hubPool should have incremented by the bond and the dataWorker should have decremented by the bond.
    expect(await weth.balanceOf(hubPool.address)).to.equal(bondAmount);
    expect(await weth.balanceOf(dataWorker.address)).to.equal(0);

    // Can only have one pending proposal at a time.
    await expect(
      hubPool
        .connect(dataWorker)
        .initiateRelayerRefund(bundleEvaluationBlockNumbers, poolRebalanceProof, destinationDistributionProof)
    ).to.be.revertedWith("Only one proposal at a time");
  });
});
