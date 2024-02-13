import {
  getParamType,
  expect,
  BigNumber,
  defaultAbiCoder,
  keccak256,
  toBNWei,
  createRandomBytes32,
  Contract,
} from "../utils/utils";
import { amountToReturn, repaymentChainId, zeroAddress } from "./constants";
import { MerkleTree } from "../utils/MerkleTree";
import { V3SlowFill } from "./fixtures/SpokePool.Fixture";
export interface PoolRebalanceLeaf {
  chainId: BigNumber;
  groupIndex: BigNumber;
  bundleLpFees: BigNumber[];
  netSendAmounts: BigNumber[];
  runningBalances: BigNumber[];
  leafId: BigNumber;
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

export async function buildRelayerRefundTree(relayerRefundLeaves: RelayerRefundLeaf[]) {
  for (let i = 0; i < relayerRefundLeaves.length; i++) {
    // The 2 provided parallel arrays must be of equal length.
    expect(relayerRefundLeaves[i].refundAddresses.length).to.equal(relayerRefundLeaves[i].refundAmounts.length);
  }

  const paramType = await getParamType("MerkleLibTest", "verifyRelayerRefund", "refund");
  const hashFn = (input: RelayerRefundLeaf) => keccak256(defaultAbiCoder.encode([paramType!], [input]));
  return new MerkleTree<RelayerRefundLeaf>(relayerRefundLeaves, hashFn);
}

export function buildRelayerRefundLeaves(
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

export async function buildPoolRebalanceLeafTree(poolRebalanceLeaves: PoolRebalanceLeaf[]) {
  for (const leaf of poolRebalanceLeaves) {
    const { l1Tokens, bundleLpFees, netSendAmounts, runningBalances } = leaf;

    // l1Tokens, bundleLpFees and netSendAmounts must always be of equal length.
    expect(l1Tokens.length).to.equal(bundleLpFees.length).to.equal(netSendAmounts.length);

    // runningBalances must be 1x or 2x as long as the other arrays. If its 2x as long, then the first half of the
    // array will be viewed as one set of running balances, and the second half will be viewed as another set of
    // of values.
    if (runningBalances.length !== l1Tokens.length) {
      expect(runningBalances.length).to.equal(2 * l1Tokens.length);
    }
  }

  const paramType = await getParamType("MerkleLibTest", "verifyPoolRebalance", "rebalance");
  const hashFn = (input: PoolRebalanceLeaf) => keccak256(defaultAbiCoder.encode([paramType!], [input]));
  return new MerkleTree<PoolRebalanceLeaf>(poolRebalanceLeaves, hashFn);
}

export function buildPoolRebalanceLeaves(
  destinationChainIds: number[],
  l1Tokens: string[][],
  bundleLpFees: BigNumber[][],
  netSendAmounts: BigNumber[][],
  runningBalances: BigNumber[][],
  groupIndex: number[]
): PoolRebalanceLeaf[] {
  return Array(destinationChainIds.length)
    .fill(0)
    .map((_, i) => {
      return {
        chainId: BigNumber.from(destinationChainIds[i]),
        groupIndex: BigNumber.from(groupIndex[i]),
        bundleLpFees: bundleLpFees[i],
        netSendAmounts: netSendAmounts[i],
        runningBalances: runningBalances[i],
        leafId: BigNumber.from(i),
        l1Tokens: l1Tokens[i],
      };
    });
}

export async function constructSingleRelayerRefundTree(l2Token: Contract | String, destinationChainId: number) {
  const leaves = buildV3RelayerRefundLeaves(
    [destinationChainId], // Destination chain ID.
    [amountToReturn], // amountToReturn.
    [l2Token as string], // l2Token.
    [[]], // refundAddresses.
    [[]], // refundAmounts.
    [createRandomBytes32()], // fillsRefundedRoot.
    [createRandomBytes32()] // fillsRefundedHash.
  );

  const tree = await buildV3RelayerRefundTree(leaves);

  return { leaves, tree };
}

export async function constructSingleChainTree(token: string, scalingSize = 1, repaymentChain = repaymentChainId) {
  const tokensSendToL2 = toBNWei(100 * scalingSize);
  const realizedLpFees = toBNWei(10 * scalingSize);
  const leaves = buildPoolRebalanceLeaves(
    [repaymentChain], // repayment chain. In this test we only want to send one token to one chain.
    [[token]], // l1Token. We will only be sending 1 token to one chain.
    [[realizedLpFees]], // bundleLpFees.
    [[tokensSendToL2]], // netSendAmounts.
    [[tokensSendToL2]], // runningBalances.
    [0] // groupIndex
  );
  const tree = await buildPoolRebalanceLeafTree(leaves);

  return { tokensSendToL2, realizedLpFees, leaves, tree };
}

export async function buildV3SlowRelayTree(slowFills: V3SlowFill[]) {
  const paramType = await getParamType("MerkleLibTest", "verifyV3SlowRelayFulfillment", "slowFill");
  const hashFn = (input: V3SlowFill) => {
    return keccak256(defaultAbiCoder.encode([paramType!], [input]));
  };
  return new MerkleTree<V3SlowFill>(slowFills, hashFn);
}
