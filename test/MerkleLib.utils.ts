import { getParamType, expect, BigNumber, Contract, defaultAbiCoder, keccak256, toBNWei } from "./utils";
import { repaymentChainId } from "./constants";
import { MerkleTree } from "../utils/MerkleTree";

export interface PoolRebalanceLeaf {
  leafId: BigNumber;
  chainId: BigNumber;
  l1Tokens: string[];
  bundleLpFees: BigNumber[];
  netSendAmounts: BigNumber[];
  runningBalances: BigNumber[];
}

export interface RelayerRefundLeaf {
  leafId: BigNumber;
  chainId: BigNumber;
  amountToReturn: BigNumber;
  l2TokenAddress: string;
  refundAddresses: string[];
  refundAmounts: BigNumber[];
}

export async function buildRelayerRefundTree(relayerRefundLeafs: RelayerRefundLeaf[]) {
  for (let i = 0; i < relayerRefundLeafs.length; i++) {
    // The 2 provided parallel arrays must be of equal length.
    expect(relayerRefundLeafs[i].refundAddresses.length).to.equal(relayerRefundLeafs[i].refundAmounts.length);
  }

  const paramType = await getParamType("MerkleLibTest", "verifyRelayerRefund", "refund");
  const hashFn = (input: RelayerRefundLeaf) => keccak256(defaultAbiCoder.encode([paramType!], [input]));
  return new MerkleTree<RelayerRefundLeaf>(relayerRefundLeafs, hashFn);
}

export function buildRelayerRefundLeafs(
  destinationChainIds: number[],
  amountsToReturn: BigNumber[],
  l2Tokens: Contract[] | string[],
  refundAddresses: string[][],
  refundAmounts: BigNumber[][]
): RelayerRefundLeaf[] {
  return Array(destinationChainIds.length)
    .fill(0)
    .map((_, i) => {
      return {
        leafId: BigNumber.from(i),
        chainId: BigNumber.from(destinationChainIds[i]),
        amountToReturn: amountsToReturn[i],
        l2TokenAddress: (l2Tokens[i] as Contract).address ?? (l2Tokens[i] as string),
        refundAddresses: refundAddresses[i],
        refundAmounts: refundAmounts[i],
      };
    });
}

export async function buildPoolRebalanceLeafTree(poolRebalanceLeafs: PoolRebalanceLeaf[]) {
  for (let i = 0; i < poolRebalanceLeafs.length; i++) {
    // The 4 provided parallel arrays must be of equal length.
    expect(poolRebalanceLeafs[i].l1Tokens.length)
      .to.equal(poolRebalanceLeafs[i].bundleLpFees.length)
      .to.equal(poolRebalanceLeafs[i].netSendAmounts.length)
      .to.equal(poolRebalanceLeafs[i].runningBalances.length);
  }

  const paramType = await getParamType("MerkleLibTest", "verifyPoolRebalance", "rebalance");
  const hashFn = (input: PoolRebalanceLeaf) => keccak256(defaultAbiCoder.encode([paramType!], [input]));
  return new MerkleTree<PoolRebalanceLeaf>(poolRebalanceLeafs, hashFn);
}

export function buildPoolRebalanceLeafs(
  destinationChainIds: number[],
  l1Tokens: string[],
  bundleLpFees: BigNumber[][],
  netSendAmounts: BigNumber[][],
  runningBalances: BigNumber[][]
): PoolRebalanceLeaf[] {
  return Array(destinationChainIds.length)
    .fill(0)
    .map((_, i) => {
      return {
        leafId: BigNumber.from(i),
        chainId: BigNumber.from(destinationChainIds[i]),
        l1Tokens: l1Tokens,
        bundleLpFees: bundleLpFees[i],
        netSendAmounts: netSendAmounts[i],
        runningBalances: runningBalances[i],
      };
    });
}

export async function constructSingleChainTree(token: string, scalingSize = 1, repaymentChain = repaymentChainId) {
  const tokensSendToL2 = toBNWei(100 * scalingSize);
  const realizedLpFees = toBNWei(10 * scalingSize);
  const leafs = buildPoolRebalanceLeafs(
    [repaymentChain], // repayment chain. In this test we only want to send one token to one chain.
    [token], // l1Token. We will only be sending 1 token to one chain.
    [[realizedLpFees]], // bundleLpFees.
    [[tokensSendToL2]], // netSendAmounts.
    [[tokensSendToL2]] // runningBalances.
  );
  const tree = await buildPoolRebalanceLeafTree(leafs);

  return { tokensSendToL2, realizedLpFees, leafs, tree };
}
