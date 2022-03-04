"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
const utils_1 = require("./utils");
const constants_1 = require("./constants");
const HubPool_Fixture_1 = require("./fixtures/HubPool.Fixture");
const MerkleLib_utils_1 = require("./MerkleLib.utils");
let hubPool, weth, timer;
let owner, dataWorker, liquidityProvider;
const initialProtocolFeeCapturePct = (0, utils_1.toBNWei)("0.1");
describe("HubPool Protocol fees", function () {
  beforeEach(async function () {
    [owner, dataWorker, liquidityProvider] = await utils_1.ethers.getSigners();
    ({ weth, hubPool, timer } = await (0, HubPool_Fixture_1.hubPoolFixture)());
    await (0, utils_1.seedWallet)(dataWorker, [], weth, constants_1.bondAmount.add(constants_1.finalFee).mul(2));
    await (0, utils_1.seedWallet)(liquidityProvider, [], weth, constants_1.amountToLp.mul(10));
    await (0, HubPool_Fixture_1.enableTokensForLP)(owner, hubPool, weth, [weth]);
    await weth.connect(liquidityProvider).approve(hubPool.address, constants_1.amountToLp);
    await hubPool.connect(liquidityProvider).addLiquidity(weth.address, constants_1.amountToLp);
    await weth.connect(dataWorker).approve(hubPool.address, constants_1.bondAmount.mul(10));
    await hubPool.setProtocolFeeCapture(owner.address, initialProtocolFeeCapturePct);
  });
  it("Only owner can set protocol fee capture", async function () {
    await (0, utils_1.expect)(
      hubPool.connect(liquidityProvider).setProtocolFeeCapture(liquidityProvider.address, (0, utils_1.toWei)("0.1"))
    ).to.be.reverted;
  });
  it("Can change protocol fee capture settings", async function () {
    (0, utils_1.expect)(await hubPool.callStatic.protocolFeeCaptureAddress()).to.equal(owner.address);
    (0, utils_1.expect)(await hubPool.callStatic.protocolFeeCapturePct()).to.equal(initialProtocolFeeCapturePct);
    const newPct = (0, utils_1.toWei)("0.1");
    await hubPool.connect(owner).setProtocolFeeCapture(liquidityProvider.address, newPct);
    (0, utils_1.expect)(await hubPool.callStatic.protocolFeeCaptureAddress()).to.equal(liquidityProvider.address);
    (0, utils_1.expect)(await hubPool.callStatic.protocolFeeCapturePct()).to.equal(newPct);
  });
  it("When fee capture pct is not set to zero fees correctly attribute between LPs and the protocol", async function () {
    const { leafs, tree, realizedLpFees } = await (0, MerkleLib_utils_1.constructSingleChainTree)(weth.address);
    await hubPool
      .connect(dataWorker)
      .proposeRootBundle([3117], 1, tree.getHexRoot(), constants_1.mockTreeRoot, constants_1.mockTreeRoot);
    await timer.setCurrentTime(Number(await timer.getCurrentTime()) + constants_1.refundProposalLiveness + 1);
    await hubPool.connect(dataWorker).executeRootBundle(leafs[0], tree.getHexProof(leafs[0]));
    // 90% of the fees should be attributed to the LPs.
    (0, utils_1.expect)((await hubPool.pooledTokens(weth.address)).undistributedLpFees).to.equal(
      realizedLpFees.mul((0, utils_1.toBNWei)("1").sub(initialProtocolFeeCapturePct)).div((0, utils_1.toBNWei)("1"))
    );
    // 10% of the fees should be attributed to the protocol.
    const expectedProtocolFees = realizedLpFees.mul(initialProtocolFeeCapturePct).div((0, utils_1.toBNWei)("1"));
    (0, utils_1.expect)(await hubPool.unclaimedAccumulatedProtocolFees(weth.address)).to.equal(expectedProtocolFees);
    // Protocol should be able to claim their fees.
    await (0, utils_1.expect)(() => hubPool.claimProtocolFeesCaptured(weth.address)).to.changeTokenBalance(
      weth,
      owner,
      expectedProtocolFees
    );
    // After claiming, the protocol fees should be zero.
    (0, utils_1.expect)(await hubPool.unclaimedAccumulatedProtocolFees(weth.address)).to.equal("0");
    // Once all the fees have been attributed the correct amount should be claimable by the LPs.
    await timer.setCurrentTime(Number(await timer.getCurrentTime()) + 10 * 24 * 60 * 60); // Move time to accumulate all fees.
    await hubPool.exchangeRateCurrent(weth.address); // force state sync.
    (0, utils_1.expect)((await hubPool.pooledTokens(weth.address)).undistributedLpFees).to.equal(0);
  });
  it("When fee capture pct is set to zero all fees accumulate to the LPs", async function () {
    await hubPool.setProtocolFeeCapture(owner.address, "0");
    const { leafs, tree, realizedLpFees } = await (0, MerkleLib_utils_1.constructSingleChainTree)(weth.address);
    await hubPool
      .connect(dataWorker)
      .proposeRootBundle([3117], 1, tree.getHexRoot(), constants_1.mockTreeRoot, constants_1.mockTreeRoot);
    await timer.setCurrentTime(Number(await timer.getCurrentTime()) + constants_1.refundProposalLiveness + 1);
    await hubPool.connect(dataWorker).executeRootBundle(leafs[0], tree.getHexProof(leafs[0]));
    (0, utils_1.expect)((await hubPool.pooledTokens(weth.address)).undistributedLpFees).to.equal(realizedLpFees);
    await timer.setCurrentTime(Number(await timer.getCurrentTime()) + 10 * 24 * 60 * 60); // Move time to accumulate all fees.
    await hubPool.exchangeRateCurrent(weth.address); // force state sync.
    (0, utils_1.expect)((await hubPool.pooledTokens(weth.address)).undistributedLpFees).to.equal(0);
    (0, utils_1.expect)(await hubPool.callStatic.exchangeRateCurrent(weth.address)).to.equal((0, utils_1.toWei)(1.01));
  });
});
