"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
const utils_1 = require("../test/utils");
const MerkleTree_1 = require("../utils/MerkleTree");
async function main() {
  console.log("Starting simple leaf generation script...");
  const poolRebalanceLeaf = {
    chainId: (0, utils_1.toBN)(421611),
    bundleLpFees: [(0, utils_1.toBNWei)(0.1)],
    netSendAmounts: [(0, utils_1.toBNWei)(1.1)],
    runningBalances: [(0, utils_1.toWei)(0)],
    leafId: (0, utils_1.toBN)(0),
    l1Tokens: ["0xc778417E063141139Fce010982780140Aa0cD5Ab"],
  };
  console.log("poolRebalanceLeaf", poolRebalanceLeaf);
  console.log(
    "tupple leaf",
    JSON.stringify(
      Object.values(poolRebalanceLeaf).map((x) => (Array.isArray(x) ? x.map((y) => y.toString()) : x.toString()))
    )
  );
  const paramType1 = await (0, utils_1.getParamType)("MerkleLibTest", "verifyPoolRebalance", "rebalance");
  const hashFn1 = (input) => (0, utils_1.keccak256)(utils_1.defaultAbiCoder.encode([paramType1], [input]));
  const poolRebalanceTree = new MerkleTree_1.MerkleTree([poolRebalanceLeaf], hashFn1);
  console.log("pool rebalance root", poolRebalanceTree.getHexRoot());
  console.log("Proof:", poolRebalanceTree.getHexProof(poolRebalanceLeaf));
  const relayerRefundLeaf = {
    leafId: (0, utils_1.toWei)(0),
    chainId: (0, utils_1.toWei)(421611),
    amountToReturn: (0, utils_1.toWei)(0),
    l2TokenAddress: "0xB47e6A5f8b33b3F17603C83a0535A9dcD7E32681",
    refundAddresses: ["0x9a8f92a830a5cb89a3816e3d267cb7791c16b04d"],
    refundAmounts: [(0, utils_1.toWei)(1)],
  };
  console.log("relayerRefundLeaf", relayerRefundLeaf);
  const paramType2 = await (0, utils_1.getParamType)("MerkleLibTest", "verifyRelayerRefund", "refund");
  const hashFn2 = (input) => (0, utils_1.keccak256)(utils_1.defaultAbiCoder.encode([paramType2], [input]));
  const relayerRefundTree = new MerkleTree_1.MerkleTree([relayerRefundLeaf], hashFn2);
  console.log("relayer refund root", relayerRefundTree.getHexRoot());
  console.log("Proof:", relayerRefundTree.getHexProof(relayerRefundLeaf));
  const slowRelayLeaf = {
    depositor: "0x9a8f92a830a5cb89a3816e3d267cb7791c16b04d",
    recipient: "0x9a8f92a830a5cb89a3816e3d267cb7791c16b04d",
    destinationToken: "0xB47e6A5f8b33b3F17603C83a0535A9dcD7E32681",
    relayAmount: "100000000000000000",
    realizedLpFeePct: "100000000000000000",
    relayerFeePct: "100000000000000000",
    depositId: "0",
    originChainId: "4",
  };
  console.log("slowRelayLeaf", slowRelayLeaf);
  const paramType3 = await (0, utils_1.getParamType)(
    "MerkleLibTest",
    "verifySlowRelayFulfillment",
    "slowRelayFulfillment"
  );
  const hashFn3 = (input) => (0, utils_1.keccak256)(utils_1.defaultAbiCoder.encode([paramType3], [input]));
  const slowRelayTree = new MerkleTree_1.MerkleTree([slowRelayLeaf], hashFn3);
  console.log("slow relayMessageCalledEvent root", slowRelayTree.getHexRoot());
  console.log("Proof:", slowRelayTree.getHexProof(slowRelayLeaf));
}
main().then(
  () => process.exit(0),
  (error) => {
    console.log(error);
    process.exit(1);
  }
);
