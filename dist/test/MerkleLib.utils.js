"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.buildSlowRelayTree =
  exports.constructSingleChainTree =
  exports.constructSingleRelayerRefundTree =
  exports.buildPoolRebalanceLeafs =
  exports.buildPoolRebalanceLeafTree =
  exports.buildRelayerRefundLeafs =
  exports.buildRelayerRefundTree =
    void 0;
const utils_1 = require("./utils");
const constants_1 = require("./constants");
const MerkleTree_1 = require("../utils/MerkleTree");
async function buildRelayerRefundTree(relayerRefundLeafs) {
  for (let i = 0; i < relayerRefundLeafs.length; i++) {
    // The 2 provided parallel arrays must be of equal length.
    (0, utils_1.expect)(relayerRefundLeafs[i].refundAddresses.length).to.equal(
      relayerRefundLeafs[i].refundAmounts.length
    );
  }
  const paramType = await (0, utils_1.getParamType)("MerkleLibTest", "verifyRelayerRefund", "refund");
  const hashFn = (input) => (0, utils_1.keccak256)(utils_1.defaultAbiCoder.encode([paramType], [input]));
  return new MerkleTree_1.MerkleTree(relayerRefundLeafs, hashFn);
}
exports.buildRelayerRefundTree = buildRelayerRefundTree;
function buildRelayerRefundLeafs(destinationChainIds, amountsToReturn, l2Tokens, refundAddresses, refundAmounts) {
  return Array(destinationChainIds.length)
    .fill(0)
    .map((_, i) => {
      return {
        leafId: utils_1.BigNumber.from(i),
        chainId: utils_1.BigNumber.from(destinationChainIds[i]),
        amountToReturn: amountsToReturn[i],
        l2TokenAddress: l2Tokens[i],
        refundAddresses: refundAddresses[i],
        refundAmounts: refundAmounts[i],
      };
    });
}
exports.buildRelayerRefundLeafs = buildRelayerRefundLeafs;
async function buildPoolRebalanceLeafTree(poolRebalanceLeafs) {
  for (let i = 0; i < poolRebalanceLeafs.length; i++) {
    // The 4 provided parallel arrays must be of equal length.
    (0, utils_1.expect)(poolRebalanceLeafs[i].l1Tokens.length)
      .to.equal(poolRebalanceLeafs[i].bundleLpFees.length)
      .to.equal(poolRebalanceLeafs[i].netSendAmounts.length)
      .to.equal(poolRebalanceLeafs[i].runningBalances.length);
  }
  const paramType = await (0, utils_1.getParamType)("MerkleLibTest", "verifyPoolRebalance", "rebalance");
  const hashFn = (input) => (0, utils_1.keccak256)(utils_1.defaultAbiCoder.encode([paramType], [input]));
  return new MerkleTree_1.MerkleTree(poolRebalanceLeafs, hashFn);
}
exports.buildPoolRebalanceLeafTree = buildPoolRebalanceLeafTree;
function buildPoolRebalanceLeafs(destinationChainIds, l1Tokens, bundleLpFees, netSendAmounts, runningBalances) {
  return Array(destinationChainIds.length)
    .fill(0)
    .map((_, i) => {
      return {
        chainId: utils_1.BigNumber.from(destinationChainIds[i]),
        l1Tokens: l1Tokens[i],
        bundleLpFees: bundleLpFees[i],
        netSendAmounts: netSendAmounts[i],
        runningBalances: runningBalances[i],
        leafId: utils_1.BigNumber.from(i),
      };
    });
}
exports.buildPoolRebalanceLeafs = buildPoolRebalanceLeafs;
async function constructSingleRelayerRefundTree(l2Token, destinationChainId) {
  const leafs = buildRelayerRefundLeafs(
    [destinationChainId], // Destination chain ID.
    [constants_1.amountToReturn], // amountToReturn.
    [l2Token], // l2Token.
    [[]], // refundAddresses.
    [[]] // refundAmounts.
  );
  const tree = await buildRelayerRefundTree(leafs);
  return { leafs, tree };
}
exports.constructSingleRelayerRefundTree = constructSingleRelayerRefundTree;
async function constructSingleChainTree(token, scalingSize = 1, repaymentChain = constants_1.repaymentChainId) {
  const tokensSendToL2 = (0, utils_1.toBNWei)(100 * scalingSize);
  const realizedLpFees = (0, utils_1.toBNWei)(10 * scalingSize);
  const leafs = buildPoolRebalanceLeafs(
    [repaymentChain], // repayment chain. In this test we only want to send one token to one chain.
    [[token]], // l1Token. We will only be sending 1 token to one chain.
    [[realizedLpFees]], // bundleLpFees.
    [[tokensSendToL2]], // netSendAmounts.
    [[tokensSendToL2]] // runningBalances.
  );
  const tree = await buildPoolRebalanceLeafTree(leafs);
  return { tokensSendToL2, realizedLpFees, leafs, tree };
}
exports.constructSingleChainTree = constructSingleChainTree;
async function buildSlowRelayTree(relays) {
  const paramType = await (0, utils_1.getParamType)(
    "MerkleLibTest",
    "verifySlowRelayFulfillment",
    "slowRelayFulfillment"
  );
  const hashFn = (input) => {
    return (0, utils_1.keccak256)(utils_1.defaultAbiCoder.encode([paramType], [input]));
  };
  return new MerkleTree_1.MerkleTree(relays, hashFn);
}
exports.buildSlowRelayTree = buildSlowRelayTree;
