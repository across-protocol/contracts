import { expect } from "chai";
import { Contract } from "ethers";
import { ethers } from "hardhat";
import { ZERO_ADDRESS, parseAncillaryData } from "@uma/common";
import { getContractFactory, SignerWithAddress, createRandomBytes32, seedWallet } from "./utils";
import * as consts from "./constants";
import { hubPoolFixture, enableTokensForLiquidityProvision } from "./HubPool.Fixture";

let hubPool: Contract, weth: Contract, optimisticOracle: Contract;
let owner: SignerWithAddress, dataWorker: SignerWithAddress, liquidityProvider: SignerWithAddress;

const mockBundleEvaluationBlockNumbers = [1, 2, 3];
const mockPoolRebalanceLeafCount = 5;
const mockPoolRebalanceRoot = createRandomBytes32();
const mockDestinationDistributionRoot = createRandomBytes32();

describe("HubPool Relayer Refund", function () {
  beforeEach(async function () {
    [owner, dataWorker, liquidityProvider] = await ethers.getSigners();
    ({ weth, hubPool, optimisticOracle } = await hubPoolFixture());
    await seedWallet(dataWorker, [], weth, consts.bondAmount);
    await seedWallet(owner, [], weth, consts.bondAmount);
    await seedWallet(dataWorker, [], weth, consts.bondAmount.add(consts.finalFee).mul(2));
    await seedWallet(liquidityProvider, [], weth, consts.amountToLp);

    await enableTokensForLiquidityProvision(owner, hubPool, [weth]);
    await weth.connect(liquidityProvider).approve(hubPool.address, consts.amountToLp);
    await hubPool.connect(liquidityProvider).addLiquidity(weth.address, consts.amountToLp);
  });

  it("Initialization of a relay correctly stores data, emits events and pulls the bond", async function () {
    const expectedRequestExpirationTimestamp = Number(await hubPool.getCurrentTime()) + consts.refundProposalLiveness;
    await weth.connect(dataWorker).approve(hubPool.address, consts.bondAmount);
    const dataWorkerWethBalancerBefore = await weth.callStatic.balanceOf(dataWorker.address);

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
    expect(await weth.balanceOf(hubPool.address)).to.equal(consts.bondAmount.add(consts.amountToLp));
    expect(await weth.balanceOf(dataWorker.address)).to.equal(dataWorkerWethBalancerBefore.sub(consts.bondAmount));

    const refundRequest = await hubPool.refundRequest();
    expect(refundRequest.requestExpirationTimestamp).to.equal(expectedRequestExpirationTimestamp);
    expect(refundRequest.unclaimedPoolRebalanceLeafCount).to.equal(mockPoolRebalanceLeafCount);
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
    ).to.be.revertedWith("Active request has unclaimed leafs");
  });
  it("Execute relayer refund correctly produces the refund bundle call and sends cross-chain repayment actions", async function () {});
  it("Dispute relayer refund correctly deletes the active request and enqueues a price request with the OO", async function () {
    await weth.connect(dataWorker).approve(hubPool.address, consts.bondAmount.mul(10));
    await hubPool
      .connect(dataWorker)
      .initiateRelayerRefund(
        mockBundleEvaluationBlockNumbers,
        mockPoolRebalanceLeafCount,
        mockPoolRebalanceRoot,
        mockDestinationDistributionRoot
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
    expect(parsedAncillaryData?.unclaimedPoolRebalanceLeafCount).to.equal(mockPoolRebalanceLeafCount);
    expect("0x" + parsedAncillaryData?.poolRebalanceRoot).to.equal(mockPoolRebalanceRoot);
    expect("0x" + parsedAncillaryData?.destinationDistributionRoot).to.equal(mockDestinationDistributionRoot);
    expect(parsedAncillaryData?.claimedBitMap).to.equal(0);
    expect(ethers.utils.getAddress("0x" + parsedAncillaryData?.proposer)).to.equal(dataWorker.address);
  });
  it("Can not dispute after proposal liveness", async function () {
    await weth.connect(dataWorker).approve(hubPool.address, consts.bondAmount.mul(10));
    await hubPool
      .connect(dataWorker)
      .initiateRelayerRefund(
        mockBundleEvaluationBlockNumbers,
        mockPoolRebalanceLeafCount,
        mockPoolRebalanceRoot,
        mockDestinationDistributionRoot
      );

    await hubPool.setCurrentTime(Number(await hubPool.getCurrentTime()) + consts.refundProposalLiveness + 1);

    await expect(hubPool.connect(dataWorker).disputeRelayerRefund()).to.be.revertedWith("Request passed liveness");
  });
});
