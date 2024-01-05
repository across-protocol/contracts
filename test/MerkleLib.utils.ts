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
import { USSSlowFill } from "./fixtures/SpokePool.Fixture";
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

export interface USSRelayerRefundLeaf extends RelayerRefundLeaf {
  fillsRefundedRoot: string;
  fillsRefundedHash: string;
}

export async function buildUSSRelayerRefundTree(
  relayerRefundLeaves: USSRelayerRefundLeaf[]
): Promise<MerkleTree<USSRelayerRefundLeaf>> {
  for (let i = 0; i < relayerRefundLeaves.length; i++) {
    // The 2 provided parallel arrays must be of equal length.
    expect(relayerRefundLeaves[i].refundAddresses.length).to.equal(relayerRefundLeaves[i].refundAmounts.length);
  }

  const paramType = await getParamType("MerkleLibTest", "verifyUSSRelayerRefund", "refund");
  const hashFn = (input: USSRelayerRefundLeaf) => keccak256(defaultAbiCoder.encode([paramType!], [input]));
  return new MerkleTree<USSRelayerRefundLeaf>(relayerRefundLeaves, hashFn);
}

export function buildUSSRelayerRefundLeaves(
  destinationChainIds: number[],
  amountsToReturn: BigNumber[],
  l2Tokens: string[],
  refundAddresses: string[][],
  refundAmounts: BigNumber[][],
  fillsRefundedRoot: string[],
  fillsRefundedHash: string[]
): USSRelayerRefundLeaf[] {
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
        fillsRefundedRoot: fillsRefundedRoot[i],
        fillsRefundedHash: fillsRefundedHash[i],
      };
    });
}

export async function buildPoolRebalanceLeafTree(poolRebalanceLeaves: PoolRebalanceLeaf[]) {
  for (const leaf of poolRebalanceLeaves) {
    const { l1Tokens, bundleLpFees, netSendAmounts, runningBalances } = leaf;

    // l1Tokens, bundleLpFees and netSendAmounts must always be of equal length.
    expect(l1Tokens.length).to.equal(bundleLpFees.length).to.equal(netSendAmounts.length);

    // runningBalances must be 1x or 2x as long as the other arrays (pre/post UBA).
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
  const leaves = buildUSSRelayerRefundLeaves(
    [destinationChainId], // Destination chain ID.
    [amountToReturn], // amountToReturn.
    [l2Token as string], // l2Token.
    [[]], // refundAddresses.
    [[]], // refundAmounts.
    [createRandomBytes32()], // fillsRefundedRoot.
    [createRandomBytes32()] // fillsRefundedHash.
  );

  const tree = await buildUSSRelayerRefundTree(leaves);

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

export async function buildUSSSlowRelayTree(slowFills: USSSlowFill[]) {
  const paramType = await getParamType("MerkleLibTest", "verifyUSSSlowRelayFulfillment", "slowFill");
  const hashFn = (input: USSSlowFill) => {
    return keccak256(defaultAbiCoder.encode([paramType!], [input]));
  };
  return new MerkleTree<USSSlowFill>(slowFills, hashFn);
}
