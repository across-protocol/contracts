"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
const MerkleLib_Fixture_1 = require("./fixtures/MerkleLib.Fixture");
const MerkleTree_1 = require("../utils/MerkleTree");
const utils_1 = require("./utils");
const utils_2 = require("./utils");
let merkleLibTest;
describe("MerkleLib Proofs", async function () {
  before(async function () {
    ({ merkleLibTest } = await (0, MerkleLib_Fixture_1.merkleLibFixture)());
  });
  it("PoolRebalanceLeaf Proof", async function () {
    const poolRebalanceLeafs = [];
    const numRebalances = 101;
    for (let i = 0; i < numRebalances; i++) {
      const numTokens = 10;
      const l1Tokens = [];
      const bundleLpFees = [];
      const netSendAmounts = [];
      const runningBalances = [];
      for (let j = 0; j < numTokens; j++) {
        l1Tokens.push((0, utils_1.randomAddress)());
        bundleLpFees.push((0, utils_1.randomBigNumber)());
        netSendAmounts.push((0, utils_1.randomBigNumber)());
        runningBalances.push((0, utils_1.randomBigNumber)());
      }
      poolRebalanceLeafs.push({
        leafId: utils_2.BigNumber.from(i),
        chainId: (0, utils_1.randomBigNumber)(),
        l1Tokens,
        bundleLpFees,
        netSendAmounts,
        runningBalances,
      });
    }
    // Remove the last element.
    const invalidPoolRebalanceLeaf = poolRebalanceLeafs.pop();
    const paramType = await (0, utils_1.getParamType)("MerkleLibTest", "verifyPoolRebalance", "rebalance");
    const hashFn = (input) => (0, utils_2.keccak256)(utils_1.defaultAbiCoder.encode([paramType], [input]));
    const merkleTree = new MerkleTree_1.MerkleTree(poolRebalanceLeafs, hashFn);
    const root = merkleTree.getHexRoot();
    const proof = merkleTree.getHexProof(poolRebalanceLeafs[34]);
    (0, utils_1.expect)(await merkleLibTest.verifyPoolRebalance(root, poolRebalanceLeafs[34], proof)).to.equal(true);
    // Verify that the excluded element fails to generate a proof and fails verification using the proof generated above.
    (0, utils_1.expect)(() => merkleTree.getHexProof(invalidPoolRebalanceLeaf)).to.throw();
    (0, utils_1.expect)(await merkleLibTest.verifyPoolRebalance(root, invalidPoolRebalanceLeaf, proof)).to.equal(false);
  });
  it("RelayerRefundLeafProof", async function () {
    const relayerRefundLeafs = [];
    const numDistributions = 101; // Create 101 and remove the last to use as the "invalid" one.
    for (let i = 0; i < numDistributions; i++) {
      const numAddresses = 10;
      const refundAddresses = [];
      const refundAmounts = [];
      for (let j = 0; j < numAddresses; j++) {
        refundAddresses.push((0, utils_1.randomAddress)());
        refundAmounts.push((0, utils_1.randomBigNumber)());
      }
      relayerRefundLeafs.push({
        leafId: utils_2.BigNumber.from(i),
        chainId: (0, utils_1.randomBigNumber)(2),
        amountToReturn: (0, utils_1.randomBigNumber)(),
        l2TokenAddress: (0, utils_1.randomAddress)(),
        refundAddresses,
        refundAmounts,
      });
    }
    // Remove the last element.
    const invalidRelayerRefundLeaf = relayerRefundLeafs.pop();
    const paramType = await (0, utils_1.getParamType)("MerkleLibTest", "verifyRelayerRefund", "refund");
    const hashFn = (input) => (0, utils_2.keccak256)(utils_1.defaultAbiCoder.encode([paramType], [input]));
    const merkleTree = new MerkleTree_1.MerkleTree(relayerRefundLeafs, hashFn);
    const root = merkleTree.getHexRoot();
    const proof = merkleTree.getHexProof(relayerRefundLeafs[14]);
    (0, utils_1.expect)(await merkleLibTest.verifyRelayerRefund(root, relayerRefundLeafs[14], proof)).to.equal(true);
    // Verify that the excluded element fails to generate a proof and fails verification using the proof generated above.
    (0, utils_1.expect)(() => merkleTree.getHexProof(invalidRelayerRefundLeaf)).to.throw();
    (0, utils_1.expect)(await merkleLibTest.verifyRelayerRefund(root, invalidRelayerRefundLeaf, proof)).to.equal(false);
  });
});
