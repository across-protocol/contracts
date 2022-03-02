import { toWei, toBN, toBNWei, getParamType, defaultAbiCoder, keccak256 } from "../test/utils";
import { MerkleTree } from "../utils/MerkleTree";
import { RelayData } from "../test/SpokePool.Fixture";

import { PoolRebalanceLeaf, RelayerRefundLeaf } from "../test/MerkleLib.utils";

async function main() {
  console.log("Starting simple leaf generation script...");

  const poolRebalanceLeaf = {
    chainId: toBN(421611),
    bundleLpFees: [toBNWei(0.1)],
    netSendAmounts: [toBNWei(1.1)],
    runningBalances: [toWei(0)],
    leafId: toBN(0),
    l1Tokens: ["0xc778417E063141139Fce010982780140Aa0cD5Ab"],
  };
  console.log("poolRebalanceLeaf", poolRebalanceLeaf);

  console.log(
    "tupple leaf",
    JSON.stringify(
      Object.values(poolRebalanceLeaf).map((x: any) =>
        Array.isArray(x) ? x.map((y: any) => y.toString()) : x.toString()
      )
    )
  );
  const paramType1 = await getParamType("MerkleLibTest", "verifyPoolRebalance", "rebalance");
  const hashFn1 = (input: PoolRebalanceLeaf) => keccak256(defaultAbiCoder.encode([paramType1!], [input]));
  const poolRebalanceTree = new MerkleTree<PoolRebalanceLeaf>([poolRebalanceLeaf], hashFn1);
  console.log("pool rebalance root", poolRebalanceTree.getHexRoot());
  console.log("Proof:", poolRebalanceTree.getHexProof(poolRebalanceLeaf));

  const relayerRefundLeaf = {
    leafId: toWei(0),
    chainId: toWei(421611),
    amountToReturn: toWei(0),
    l2TokenAddress: "0xB47e6A5f8b33b3F17603C83a0535A9dcD7E32681",
    refundAddresses: ["0x9a8f92a830a5cb89a3816e3d267cb7791c16b04d"],
    refundAmounts: [toWei(1)],
  };

  console.log("relayerRefundLeaf", relayerRefundLeaf);
  const paramType2 = await getParamType("MerkleLibTest", "verifyRelayerRefund", "refund");
  const hashFn2 = (input: RelayerRefundLeaf) => keccak256(defaultAbiCoder.encode([paramType2!], [input]));
  const relayerRefundTree = new MerkleTree<RelayerRefundLeaf>([relayerRefundLeaf], hashFn2);
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
  const paramType3 = await getParamType("MerkleLibTest", "verifySlowRelayFulfillment", "slowRelayFulfillment");
  const hashFn3 = (input: RelayData) => keccak256(defaultAbiCoder.encode([paramType3!], [input]));
  const slowRelayTree = new MerkleTree<RelayData>([slowRelayLeaf], hashFn3);
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
