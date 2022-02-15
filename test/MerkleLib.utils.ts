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

export interface DestinationDistributionLeaf {
  leafId: BigNumber;
  chainId: BigNumber;
  amountToReturn: BigNumber;
  l2TokenAddress: string;
  refundAddresses: string[];
  refundAmounts: BigNumber[];
}

export async function buildDestinationDistributionLeafTree(
  destinationDistributionLeafs: DestinationDistributionLeaf[]
) {
  for (let i = 0; i < destinationDistributionLeafs.length; i++) {
    // The 2 provided parallel arrays must be of equal length.
    expect(destinationDistributionLeafs[i].refundAddresses.length).to.equal(
      destinationDistributionLeafs[i].refundAmounts.length
    );
  }

  const paramType = await getParamType("MerkleLib", "verifyRelayerDistribution", "distribution");
  const hashFn = (input: DestinationDistributionLeaf) => keccak256(defaultAbiCoder.encode([paramType!], [input]));
  return new MerkleTree<DestinationDistributionLeaf>(destinationDistributionLeafs, hashFn);
}

export function buildDestinationDistributionLeafs(
  destinationChainIds: number[],
  amountsToReturn: BigNumber[],
  l2Tokens: Contract[],
  refundAddresses: string[][],
  refundAmounts: BigNumber[][]
): DestinationDistributionLeaf[] {
  return Array(destinationChainIds.length)
    .fill(0)
    .map((_, i) => {
      return {
        leafId: BigNumber.from(i),
        chainId: BigNumber.from(destinationChainIds[i]),
        amountToReturn: amountsToReturn[i],
        l2TokenAddress: l2Tokens[i].address,
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

  const paramType = await getParamType("MerkleLib", "verifyPoolRebalance", "rebalance");
  const hashFn = (input: PoolRebalanceLeaf) => keccak256(defaultAbiCoder.encode([paramType!], [input]));
  return new MerkleTree<PoolRebalanceLeaf>(poolRebalanceLeafs, hashFn);
}

export function buildPoolRebalanceLeafs(
  destinationChainIds: number[],
  l1Tokens: Contract[][],
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
        l1Tokens: l1Tokens[i].map((token: Contract) => token.address),
        bundleLpFees: bundleLpFees[i],
        netSendAmounts: netSendAmounts[i],
        runningBalances: runningBalances[i],
      };
    });
}

export async function constructSingleChainTree(token: Contract, scalingSize = 1, repaymentChain = repaymentChainId) {
  const tokensSendToL2 = toBNWei(100 * scalingSize);
  const realizedLpFees = toBNWei(10 * scalingSize);
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
