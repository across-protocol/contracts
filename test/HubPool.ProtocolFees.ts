import { toWei, toBNWei, SignerWithAddress, seedWallet, expect, Contract, ethers } from "./utils";
import { mockTreeRoot, finalFee, bondAmount, amountToLp, refundProposalLiveness } from "./constants";
import { hubPoolFixture, enableTokensForLP } from "./HubPool.Fixture";
import { constructSingleChainTree } from "./MerkleLib.utils";

let hubPool: Contract, weth: Contract, timer: Contract;
let owner: SignerWithAddress, dataWorker: SignerWithAddress, liquidityProvider: SignerWithAddress;

const initialProtocolFeeCapturePct = toBNWei("0.1");

describe("HubPool Protocol fees", function () {
  beforeEach(async function () {
    [owner, dataWorker, liquidityProvider] = await ethers.getSigners();
    ({ weth, hubPool, timer } = await hubPoolFixture());
    await seedWallet(dataWorker, [], weth, bondAmount.add(finalFee).mul(2));
    await seedWallet(liquidityProvider, [], weth, amountToLp.mul(10));

    await enableTokensForLP(owner, hubPool, weth, [weth]);
    await weth.connect(liquidityProvider).approve(hubPool.address, amountToLp);
    await hubPool.connect(liquidityProvider).addLiquidity(weth.address, amountToLp);
    await weth.connect(dataWorker).approve(hubPool.address, bondAmount.mul(10));

    await hubPool.setProtocolFeeCapturePct(initialProtocolFeeCapturePct);
  });

  it("Only owner can set protocol fee capture address", async function () {
    await expect(hubPool.connect(liquidityProvider).setProtocolFeeCaptureAddress(liquidityProvider.address)).to.be
      .reverted;
  });
  it("Can change protocol fee capture address", async function () {
    expect(await hubPool.callStatic.protocolFeeCaptureAddress()).to.equal(owner.address);
    await hubPool.connect(owner).setProtocolFeeCaptureAddress(liquidityProvider.address);
    expect(await hubPool.callStatic.protocolFeeCaptureAddress()).to.equal(liquidityProvider.address);
  });
  it("Only owner can set protocol fee capture pct", async function () {
    await expect(hubPool.connect(liquidityProvider).setProtocolFeeCapturePct(liquidityProvider.address)).to.be.reverted;
  });
  it("Can change protocol fee capture pct", async function () {
    expect(await hubPool.callStatic.protocolFeeCapturePct()).to.equal(initialProtocolFeeCapturePct);
    const newPct = toWei("0.1");
    await hubPool.connect(owner).setProtocolFeeCapturePct(newPct);
    expect(await hubPool.callStatic.protocolFeeCapturePct()).to.equal(newPct);
  });
  it("When fee capture pct is not set to zero fees correctly attribute between LPs and the protocol", async function () {
    const { leafs, tree, realizedLpFees } = await constructSingleChainTree(weth);
    await hubPool.connect(dataWorker).initiateRelayerRefund([3117], 1, tree.getHexRoot(), mockTreeRoot, mockTreeRoot);
    await timer.setCurrentTime(Number(await timer.getCurrentTime()) + refundProposalLiveness);
    await hubPool.connect(dataWorker).executeRelayerRefund(leafs[0], tree.getHexProof(leafs[0]));

    // 90% of the fees should be attributed to the LPs.
    expect((await hubPool.pooledTokens(weth.address)).undistributedLpFees).to.equal(
      realizedLpFees.mul(toBNWei("1").sub(initialProtocolFeeCapturePct)).div(toBNWei("1"))
    );

    // 10% of the fees should be attributed to the protocol.
    const expectedProtocolFees = realizedLpFees.mul(initialProtocolFeeCapturePct).div(toBNWei("1"));
    expect(await hubPool.unclaimedAccumulatedProtocolFees(weth.address)).to.equal(expectedProtocolFees);

    // Protocol should be able to claim their fees.
    await expect(() => hubPool.claimProtocolFeesCaptured(weth.address)).to.changeTokenBalance(
      weth,
      owner,
      expectedProtocolFees
    );

    // After claiming, the protocol fees should be zero.
    expect(await hubPool.unclaimedAccumulatedProtocolFees(weth.address)).to.equal("0");

    // Once all the fees have been attributed the correct amount should be claimable by the LPs.
    await timer.setCurrentTime(Number(await timer.getCurrentTime()) + 10 * 24 * 60 * 60); // Move time to accumulate all fees.
    await hubPool.exchangeRateCurrent(weth.address); // force state sync.
    expect((await hubPool.pooledTokens(weth.address)).undistributedLpFees).to.equal(0);
  });
  it("When fee capture pct is set to zero all fees accumulate to the LPs", async function () {
    await hubPool.setProtocolFeeCapturePct("0");
    const { leafs, tree, realizedLpFees } = await constructSingleChainTree(weth);
    await hubPool.connect(dataWorker).initiateRelayerRefund([3117], 1, tree.getHexRoot(), mockTreeRoot, mockTreeRoot);
    await timer.setCurrentTime(Number(await timer.getCurrentTime()) + refundProposalLiveness);
    await hubPool.connect(dataWorker).executeRelayerRefund(leafs[0], tree.getHexProof(leafs[0]));
    expect((await hubPool.pooledTokens(weth.address)).undistributedLpFees).to.equal(realizedLpFees);

    await timer.setCurrentTime(Number(await timer.getCurrentTime()) + 10 * 24 * 60 * 60); // Move time to accumulate all fees.
    await hubPool.exchangeRateCurrent(weth.address); // force state sync.
    expect((await hubPool.pooledTokens(weth.address)).undistributedLpFees).to.equal(0);
    expect(await hubPool.callStatic.exchangeRateCurrent(weth.address)).to.equal(toWei(1.01));
  });
});
