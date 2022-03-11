import { getParamType, expect, BigNumber, Contract, defaultAbiCoder, keccak256, toBNWei } from "./utils";
import { repaymentChainId, amountToReturn } from "./constants";
import { MerkleTree } from "../utils/MerkleTree";
import { RelayData } from "./fixtures/SpokePool.Fixture";
export interface PoolRebalanceLeaf {
  chainId: BigNumber;
  bundleLpFees: BigNumber[];
  netSendAmounts: BigNumber[];
  runningBalances: BigNumber[];
  leafId: BigNumber;
  relayToSpokePool: boolean;
  l1Tokens: string[];
}

export interface RelayerRefundLeaf {
  amountToReturn: BigNumber;
  chainId: BigNumber;
  refundAmounts: BigNumber[];
  leafId: BigNumber;
  l2TokenAddress: string;
  refundAddresses: string[];
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
  l2Tokens: string[],
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
        l2TokenAddress: l2Tokens[i],
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
  l1Tokens: string[][],
  bundleLpFees: BigNumber[][],
  netSendAmounts: BigNumber[][],
  runningBalances: BigNumber[][],
  relayToSpokePool: boolean[]
): PoolRebalanceLeaf[] {
  return Array(destinationChainIds.length)
    .fill(0)
    .map((_, i) => {
      return {
        chainId: BigNumber.from(destinationChainIds[i]),
        bundleLpFees: bundleLpFees[i],
        netSendAmounts: netSendAmounts[i],
        runningBalances: runningBalances[i],
        leafId: BigNumber.from(i),
        relayToSpokePool: relayToSpokePool[i],
        l1Tokens: l1Tokens[i],
      };
    });
}

export async function constructSingleRelayerRefundTree(l2Token: Contract | String, destinationChainId: number) {
  const leafs = buildRelayerRefundLeafs(
    [destinationChainId], // Destination chain ID.
    [amountToReturn], // amountToReturn.
    [l2Token as string], // l2Token.
    [[]], // refundAddresses.
    [[]] // refundAmounts.
  );

  const tree = await buildRelayerRefundTree(leafs);

  return { leafs, tree };
}

export async function constructSingleChainTree(token: string, scalingSize = 1, repaymentChain = repaymentChainId) {
  const tokensSendToL2 = toBNWei(100 * scalingSize);
  const realizedLpFees = toBNWei(10 * scalingSize);
  const leafs = buildPoolRebalanceLeafs(
    [repaymentChain], // repayment chain. In this test we only want to send one token to one chain.
    [[token]], // l1Token. We will only be sending 1 token to one chain.
    [[realizedLpFees]], // bundleLpFees.
    [[tokensSendToL2]], // netSendAmounts.
    [[tokensSendToL2]], // runningBalances.
    [true] // relayToSpokePool
  );
  const tree = await buildPoolRebalanceLeafTree(leafs);

  return { tokensSendToL2, realizedLpFees, leafs, tree };
}

export async function buildSlowRelayTree(relays: RelayData[]) {
  const paramType = await getParamType("MerkleLibTest", "verifySlowRelayFulfillment", "slowRelayFulfillment");
  const hashFn = (input: RelayData) => {
    return keccak256(defaultAbiCoder.encode([paramType!], [input]));
  };
  return new MerkleTree(relays, hashFn);
}
