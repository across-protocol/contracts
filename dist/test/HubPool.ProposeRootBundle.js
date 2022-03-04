"use strict";
var __createBinding =
  (this && this.__createBinding) ||
  (Object.create
    ? function (o, m, k, k2) {
        if (k2 === undefined) k2 = k;
        Object.defineProperty(o, k2, {
          enumerable: true,
          get: function () {
            return m[k];
          },
        });
      }
    : function (o, m, k, k2) {
        if (k2 === undefined) k2 = k;
        o[k2] = m[k];
      });
var __setModuleDefault =
  (this && this.__setModuleDefault) ||
  (Object.create
    ? function (o, v) {
        Object.defineProperty(o, "default", { enumerable: true, value: v });
      }
    : function (o, v) {
        o["default"] = v;
      });
var __importStar =
  (this && this.__importStar) ||
  function (mod) {
    if (mod && mod.__esModule) return mod;
    var result = {};
    if (mod != null)
      for (var k in mod)
        if (k !== "default" && Object.prototype.hasOwnProperty.call(mod, k)) __createBinding(result, mod, k);
    __setModuleDefault(result, mod);
    return result;
  };
Object.defineProperty(exports, "__esModule", { value: true });
const utils_1 = require("./utils");
const consts = __importStar(require("./constants"));
const HubPool_Fixture_1 = require("./fixtures/HubPool.Fixture");
let hubPool, weth, dataWorker;
describe("HubPool Root Bundle Proposal", function () {
  beforeEach(async function () {
    [dataWorker] = await utils_1.ethers.getSigners();
    ({ weth, hubPool } = await (0, HubPool_Fixture_1.hubPoolFixture)());
    await (0, utils_1.seedWallet)(dataWorker, [], weth, consts.totalBond);
  });
  it("Proposal of root bundle correctly stores data, emits events and pulls the bond", async function () {
    const expectedRequestExpirationTimestamp = Number(await hubPool.getCurrentTime()) + consts.refundProposalLiveness;
    await weth.connect(dataWorker).approve(hubPool.address, consts.totalBond);
    const dataWorkerWethBalancerBefore = await weth.callStatic.balanceOf(dataWorker.address);
    await (0, utils_1.expect)(
      hubPool
        .connect(dataWorker)
        .proposeRootBundle(
          consts.mockBundleEvaluationBlockNumbers,
          consts.mockPoolRebalanceLeafCount,
          consts.mockPoolRebalanceRoot,
          consts.mockRelayerRefundRoot,
          consts.mockSlowRelayRoot
        )
    )
      .to.emit(hubPool, "ProposeRootBundle")
      .withArgs(
        expectedRequestExpirationTimestamp,
        consts.mockPoolRebalanceLeafCount,
        consts.mockBundleEvaluationBlockNumbers,
        consts.mockPoolRebalanceRoot,
        consts.mockRelayerRefundRoot,
        consts.mockSlowRelayRoot,
        dataWorker.address
      );
    // Balances of the hubPool should have incremented by the bond and the dataWorker should have decremented by the bond.
    (0, utils_1.expect)(await weth.balanceOf(hubPool.address)).to.equal(consts.totalBond);
    (0, utils_1.expect)(await weth.balanceOf(dataWorker.address)).to.equal(
      dataWorkerWethBalancerBefore.sub(consts.totalBond)
    );
    const rootBundle = await hubPool.rootBundleProposal();
    (0, utils_1.expect)(rootBundle.requestExpirationTimestamp).to.equal(expectedRequestExpirationTimestamp);
    (0, utils_1.expect)(rootBundle.unclaimedPoolRebalanceLeafCount).to.equal(consts.mockPoolRebalanceLeafCount);
    (0, utils_1.expect)(rootBundle.poolRebalanceRoot).to.equal(consts.mockPoolRebalanceRoot);
    (0, utils_1.expect)(rootBundle.relayerRefundRoot).to.equal(consts.mockRelayerRefundRoot);
    (0, utils_1.expect)(rootBundle.claimedBitMap).to.equal(0); // no claims yet so everything should be marked at 0.
    (0, utils_1.expect)(rootBundle.proposer).to.equal(dataWorker.address);
    (0, utils_1.expect)(rootBundle.proposerBondRepaid).to.equal(false);
    // Can not re-initialize if the previous bundle has unclaimed leaves.
    await (0, utils_1.expect)(
      hubPool
        .connect(dataWorker)
        .proposeRootBundle(
          consts.mockBundleEvaluationBlockNumbers,
          consts.mockPoolRebalanceLeafCount,
          consts.mockPoolRebalanceRoot,
          consts.mockRelayerRefundRoot,
          consts.mockSlowRelayRoot
        )
    ).to.be.revertedWith("proposal has unclaimed leafs");
  });
});
