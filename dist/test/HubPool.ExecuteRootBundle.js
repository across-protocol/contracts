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
const MerkleLib_utils_1 = require("./MerkleLib.utils");
let hubPool, mockAdapter, weth, dai, mockSpoke, timer;
let owner, dataWorker, liquidityProvider;
let l2Weth, l2Dai;
// Construct the leafs that will go into the merkle tree. For this function create a simple set of leafs that will
// repay two token to one chain Id with simple lpFee, netSend and running balance amounts.
async function constructSimpleTree() {
  const wethToSendToL2 = (0, utils_1.toBNWei)(100);
  const daiToSend = (0, utils_1.toBNWei)(1000);
  const leafs = (0, MerkleLib_utils_1.buildPoolRebalanceLeafs)(
    [consts.repaymentChainId], // repayment chain. In this test we only want to send one token to one chain.
    [[weth.address, dai.address]], // l1Token. We will only be sending WETH and DAI to the associated repayment chain.
    [[(0, utils_1.toBNWei)(1), (0, utils_1.toBNWei)(10)]], // bundleLpFees. Set to 1 ETH and 10 DAI respectively to attribute to the LPs.
    [[wethToSendToL2, daiToSend]], // netSendAmounts. Set to 100 ETH and 1000 DAI as the amount to send from L1->L2.
    [[wethToSendToL2, daiToSend]] // runningBalances. Set to 100 ETH and 1000 DAI.
  );
  const tree = await (0, MerkleLib_utils_1.buildPoolRebalanceLeafTree)(leafs);
  return { wethToSendToL2, daiToSend, leafs, tree };
}
describe("HubPool Root Bundle Execution", function () {
  beforeEach(async function () {
    [owner, dataWorker, liquidityProvider] = await utils_1.ethers.getSigners();
    ({ weth, dai, hubPool, mockAdapter, mockSpoke, timer, l2Weth, l2Dai } = await (0,
    HubPool_Fixture_1.hubPoolFixture)());
    await (0, utils_1.seedWallet)(dataWorker, [dai], weth, consts.bondAmount.add(consts.finalFee).mul(2));
    await (0, utils_1.seedWallet)(liquidityProvider, [dai], weth, consts.amountToLp.mul(10));
    await (0, HubPool_Fixture_1.enableTokensForLP)(owner, hubPool, weth, [weth, dai]);
    await weth.connect(liquidityProvider).approve(hubPool.address, consts.amountToLp);
    await hubPool.connect(liquidityProvider).addLiquidity(weth.address, consts.amountToLp);
    await dai.connect(liquidityProvider).approve(hubPool.address, consts.amountToLp.mul(10)); // LP with 10000 DAI.
    await hubPool.connect(liquidityProvider).addLiquidity(dai.address, consts.amountToLp.mul(10));
    await weth.connect(dataWorker).approve(hubPool.address, consts.bondAmount.mul(10));
  });
  it("Executing root bundle correctly produces the relay bundle call and sends repayment actions", async function () {
    var _a, _b, _c, _d, _e, _f, _g, _h, _j, _k;
    const { wethToSendToL2, daiToSend, leafs, tree } = await constructSimpleTree();
    await hubPool.connect(dataWorker).proposeRootBundle(
      [3117], // bundleEvaluationBlockNumbers used by bots to construct bundles. Length must equal the number of leafs.
      1, // poolRebalanceLeafCount. There is exactly one leaf in the bundle (just sending WETH to one address).
      tree.getHexRoot(), // poolRebalanceRoot. Generated from the merkle tree constructed before.
      consts.mockRelayerRefundRoot, // Not relevant for this test.
      consts.mockSlowRelayRoot // Not relevant for this test.
    );
    // Advance time so the request can be executed and execute the request.
    await timer.setCurrentTime(Number(await timer.getCurrentTime()) + consts.refundProposalLiveness + 1);
    await hubPool.connect(dataWorker).executeRootBundle(leafs[0], tree.getHexProof(leafs[0]));
    // Balances should have updated as expected.
    (0, utils_1.expect)(await weth.balanceOf(hubPool.address)).to.equal(consts.amountToLp.sub(wethToSendToL2));
    (0, utils_1.expect)(await weth.balanceOf(await mockAdapter.bridge())).to.equal(wethToSendToL2);
    (0, utils_1.expect)(await dai.balanceOf(hubPool.address)).to.equal(consts.amountToLp.mul(10).sub(daiToSend));
    (0, utils_1.expect)(await dai.balanceOf(await mockAdapter.bridge())).to.equal(daiToSend);
    // Since the mock adapter is delegatecalled, when querying, its address should be the hubPool address.
    const mockAdapterAtHubPool = mockAdapter.attach(hubPool.address);
    // Check the mockAdapter was called with the correct arguments for each method.
    const relayMessageEvents = await mockAdapterAtHubPool.queryFilter(
      mockAdapterAtHubPool.filters.RelayMessageCalled()
    );
    (0, utils_1.expect)(relayMessageEvents.length).to.equal(7); // Exactly seven message send from L1->L2. 6 for each whitelist route
    // and 1 for the initiateRelayerRefund.
    (0, utils_1.expect)(
      (_a = relayMessageEvents[relayMessageEvents.length - 1].args) === null || _a === void 0 ? void 0 : _a.target
    ).to.equal(mockSpoke.address);
    (0, utils_1.expect)(
      (_b = relayMessageEvents[relayMessageEvents.length - 1].args) === null || _b === void 0 ? void 0 : _b.message
    ).to.equal(
      mockSpoke.interface.encodeFunctionData("relayRootBundle", [
        consts.mockRelayerRefundRoot,
        consts.mockSlowRelayRoot,
      ])
    );
    const relayTokensEvents = await mockAdapterAtHubPool.queryFilter(mockAdapterAtHubPool.filters.RelayTokensCalled());
    (0, utils_1.expect)(relayTokensEvents.length).to.equal(2); // Exactly two token transfers from L1->L2.
    (0, utils_1.expect)((_c = relayTokensEvents[0].args) === null || _c === void 0 ? void 0 : _c.l1Token).to.equal(
      weth.address
    );
    (0, utils_1.expect)((_d = relayTokensEvents[0].args) === null || _d === void 0 ? void 0 : _d.l2Token).to.equal(
      l2Weth
    );
    (0, utils_1.expect)((_e = relayTokensEvents[0].args) === null || _e === void 0 ? void 0 : _e.amount).to.equal(
      wethToSendToL2
    );
    (0, utils_1.expect)((_f = relayTokensEvents[0].args) === null || _f === void 0 ? void 0 : _f.to).to.equal(
      mockSpoke.address
    );
    (0, utils_1.expect)((_g = relayTokensEvents[1].args) === null || _g === void 0 ? void 0 : _g.l1Token).to.equal(
      dai.address
    );
    (0, utils_1.expect)((_h = relayTokensEvents[1].args) === null || _h === void 0 ? void 0 : _h.l2Token).to.equal(
      l2Dai
    );
    (0, utils_1.expect)((_j = relayTokensEvents[1].args) === null || _j === void 0 ? void 0 : _j.amount).to.equal(
      daiToSend
    );
    (0, utils_1.expect)((_k = relayTokensEvents[1].args) === null || _k === void 0 ? void 0 : _k.to).to.equal(
      mockSpoke.address
    );
    // Check the leaf count was decremented correctly.
    (0, utils_1.expect)((await hubPool.rootBundleProposal()).unclaimedPoolRebalanceLeafCount).to.equal(0);
  });
  it("Execution rejects leaf claim before liveness passed", async function () {
    const { leafs, tree } = await constructSimpleTree();
    await hubPool
      .connect(dataWorker)
      .proposeRootBundle([3117], 1, tree.getHexRoot(), consts.mockRelayerRefundRoot, consts.mockSlowRelayRoot);
    // Set time 10 seconds before expiration. Should revert.
    await timer.setCurrentTime(Number(await timer.getCurrentTime()) + consts.refundProposalLiveness - 10);
    await (0, utils_1.expect)(
      hubPool.connect(dataWorker).executeRootBundle(leafs[0], tree.getHexProof(leafs[0]))
    ).to.be.revertedWith("Not passed liveness");
    // Set time after expiration. Should no longer revert.
    await timer.setCurrentTime(Number(await timer.getCurrentTime()) + 11);
    await hubPool.connect(dataWorker).executeRootBundle(leafs[0], tree.getHexProof(leafs[0]));
  });
  it("Execution rejects invalid leafs", async function () {
    const { leafs, tree } = await constructSimpleTree();
    await hubPool
      .connect(dataWorker)
      .proposeRootBundle([3117], 1, tree.getHexRoot(), consts.mockRelayerRefundRoot, consts.mockSlowRelayRoot);
    await timer.setCurrentTime(Number(await timer.getCurrentTime()) + consts.refundProposalLiveness + 1);
    // Take the valid root but change some element within it, such as the chainId. This will change the hash of the leaf
    // and as such the contract should reject it for not being included within the merkle tree for the valid proof.
    const badLeaf = { ...leafs[0], chainId: 13371 };
    await (0, utils_1.expect)(
      hubPool.connect(dataWorker).executeRootBundle(badLeaf, tree.getHexProof(leafs[0]))
    ).to.be.revertedWith("Bad Proof");
  });
  it("Execution rejects double claimed leafs", async function () {
    const { leafs, tree } = await constructSimpleTree();
    await hubPool
      .connect(dataWorker)
      .proposeRootBundle([3117], 1, tree.getHexRoot(), consts.mockRelayerRefundRoot, consts.mockSlowRelayRoot);
    await timer.setCurrentTime(Number(await timer.getCurrentTime()) + consts.refundProposalLiveness + 1);
    // First claim should be fine. Second claim should be reverted as you cant double claim a leaf.
    await hubPool.connect(dataWorker).executeRootBundle(leafs[0], tree.getHexProof(leafs[0]));
    await (0, utils_1.expect)(
      hubPool.connect(dataWorker).executeRootBundle(leafs[0], tree.getHexProof(leafs[0]))
    ).to.be.revertedWith("Already claimed");
  });
});
