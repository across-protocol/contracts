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
const SpokePool_Fixture_1 = require("./fixtures/SpokePool.Fixture");
const MerkleLib_utils_1 = require("./MerkleLib.utils");
let spokePool, destErc20, weth;
let dataWorker, relayer, rando;
let destinationChainId;
async function constructSimpleTree(l2Token, destinationChainId) {
  const leafs = (0, MerkleLib_utils_1.buildRelayerRefundLeafs)(
    [destinationChainId, destinationChainId], // Destination chain ID.
    [consts.amountToReturn, (0, utils_1.toBN)(0)], // amountToReturn.
    [l2Token.address, l2Token.address], // l2Token.
    [[relayer.address, rando.address], []], // refundAddresses.
    [[consts.amountToRelay, consts.amountToRelay], []] // refundAmounts.
  );
  const leafsRefundAmount = leafs
    .map((leaf) => leaf.refundAmounts.reduce((bn1, bn2) => bn1.add(bn2), (0, utils_1.toBN)(0)))
    .reduce((bn1, bn2) => bn1.add(bn2), (0, utils_1.toBN)(0));
  const tree = await (0, MerkleLib_utils_1.buildRelayerRefundTree)(leafs);
  return { leafs, leafsRefundAmount, tree };
}
describe("SpokePool Root Bundle Execution", function () {
  beforeEach(async function () {
    [dataWorker, relayer, rando] = await utils_1.ethers.getSigners();
    ({ destErc20, spokePool, weth } = await (0, SpokePool_Fixture_1.spokePoolFixture)());
    destinationChainId = Number(await spokePool.chainId());
    // Send funds to SpokePool.
    await (0, utils_1.seedContract)(spokePool, dataWorker, [destErc20], weth, consts.amountHeldByPool);
  });
  it("Execute relayer root correctly sends tokens to recipients", async function () {
    var _a, _b, _c, _d, _e, _f, _g;
    const { leafs, leafsRefundAmount, tree } = await constructSimpleTree(destErc20, destinationChainId);
    // Store new tree.
    await spokePool.connect(dataWorker).relayRootBundle(
      tree.getHexRoot(), // relayer refund root. Generated from the merkle tree constructed before.
      consts.mockSlowRelayRoot
    );
    // Distribute the first leaf.
    await spokePool.connect(dataWorker).executeRelayerRefundRoot(0, leafs[0], tree.getHexProof(leafs[0]));
    // Relayers should be refunded
    (0, utils_1.expect)(await destErc20.balanceOf(spokePool.address)).to.equal(
      consts.amountHeldByPool.sub(leafsRefundAmount)
    );
    (0, utils_1.expect)(await destErc20.balanceOf(relayer.address)).to.equal(consts.amountToRelay);
    (0, utils_1.expect)(await destErc20.balanceOf(rando.address)).to.equal(consts.amountToRelay);
    // Check events.
    let relayTokensEvents = await spokePool.queryFilter(spokePool.filters.ExecutedRelayerRefundRoot());
    (0, utils_1.expect)(
      (_a = relayTokensEvents[0].args) === null || _a === void 0 ? void 0 : _a.l2TokenAddress
    ).to.equal(destErc20.address);
    (0, utils_1.expect)((_b = relayTokensEvents[0].args) === null || _b === void 0 ? void 0 : _b.leafId).to.equal(0);
    (0, utils_1.expect)((_c = relayTokensEvents[0].args) === null || _c === void 0 ? void 0 : _c.chainId).to.equal(
      destinationChainId
    );
    (0, utils_1.expect)(
      (_d = relayTokensEvents[0].args) === null || _d === void 0 ? void 0 : _d.amountToReturn
    ).to.equal(consts.amountToReturn);
    (0, utils_1.expect)(
      (_e = relayTokensEvents[0].args) === null || _e === void 0 ? void 0 : _e.refundAmounts
    ).to.deep.equal([consts.amountToRelay, consts.amountToRelay]);
    (0, utils_1.expect)(
      (_f = relayTokensEvents[0].args) === null || _f === void 0 ? void 0 : _f.refundAddresses
    ).to.deep.equal([relayer.address, rando.address]);
    (0, utils_1.expect)((_g = relayTokensEvents[0].args) === null || _g === void 0 ? void 0 : _g.caller).to.equal(
      dataWorker.address
    );
    // Should emit TokensBridged event if amountToReturn is positive.
    let tokensBridgedEvents = await spokePool.queryFilter(spokePool.filters.TokensBridged());
    (0, utils_1.expect)(tokensBridgedEvents.length).to.equal(1);
    // Does not attempt to bridge tokens if amountToReturn is 0. Execute a leaf where amountToReturn is 0.
    await spokePool.connect(dataWorker).executeRelayerRefundRoot(0, leafs[1], tree.getHexProof(leafs[1]));
    // Show that a second DistributedRelayRefund event was emitted but not a second TokensBridged event.
    relayTokensEvents = await spokePool.queryFilter(spokePool.filters.ExecutedRelayerRefundRoot());
    (0, utils_1.expect)(relayTokensEvents.length).to.equal(2);
    tokensBridgedEvents = await spokePool.queryFilter(spokePool.filters.TokensBridged());
    (0, utils_1.expect)(tokensBridgedEvents.length).to.equal(1);
  });
  it("Execution rejects invalid leaf, tree, proof combinations", async function () {
    const { leafs, tree } = await constructSimpleTree(destErc20, destinationChainId);
    await spokePool.connect(dataWorker).relayRootBundle(
      tree.getHexRoot(), // distribution root. Generated from the merkle tree constructed before.
      consts.mockSlowRelayRoot
    );
    // Take the valid root but change some element within it. This will change the hash of the leaf
    // and as such the contract should reject it for not being included within the merkle tree for the valid proof.
    const badLeaf = { ...leafs[0], chainId: 13371 };
    await (0, utils_1.expect)(
      spokePool.connect(dataWorker).executeRelayerRefundRoot(0, badLeaf, tree.getHexProof(leafs[0]))
    ).to.be.reverted;
    // Reverts if the distribution root index is incorrect.
    await (0, utils_1.expect)(
      spokePool.connect(dataWorker).executeRelayerRefundRoot(1, leafs[0], tree.getHexProof(leafs[0]))
    ).to.be.reverted;
  });
  it("Cannot refund leaf with chain ID for another network", async function () {
    // Create tree for another chain ID
    const { leafs, tree } = await constructSimpleTree(destErc20, 13371);
    await spokePool.connect(dataWorker).relayRootBundle(
      tree.getHexRoot(), // distribution root. Generated from the merkle tree constructed before.
      consts.mockSlowRelayRoot
    );
    // Root is valid and leaf is contained in tree, but chain ID doesn't match pool's chain ID.
    await (0, utils_1.expect)(
      spokePool.connect(dataWorker).executeRelayerRefundRoot(0, leafs[0], tree.getHexProof(leafs[0]))
    ).to.be.reverted;
  });
  it("Execution rejects double claimed leafs", async function () {
    const { leafs, tree } = await constructSimpleTree(destErc20, destinationChainId);
    await spokePool.connect(dataWorker).relayRootBundle(
      tree.getHexRoot(), // distribution root. Generated from the merkle tree constructed before.
      consts.mockSlowRelayRoot
    );
    // First claim should be fine. Second claim should be reverted as you cant double claim a leaf.
    await spokePool.connect(dataWorker).executeRelayerRefundRoot(0, leafs[0], tree.getHexProof(leafs[0]));
    await (0, utils_1.expect)(
      spokePool.connect(dataWorker).executeRelayerRefundRoot(0, leafs[0], tree.getHexProof(leafs[0]))
    ).to.be.reverted;
  });
});
