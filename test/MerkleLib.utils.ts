import { expect } from "chai";
import { getParamType } from "./utils";
import { merkleLibFixture } from "./MerkleLib.Fixture";
import { MerkleTree } from "../utils/MerkleTree";
import { ethers } from "hardhat";
const { defaultAbiCoder, keccak256 } = ethers.utils;
import { BigNumber, Signer, Contract } from "ethers";

export interface PoolRebalance {
  leafId: BigNumber;
  chainId: BigNumber;
  l1Token: string[];
  bundleLpFees: BigNumber[];
  netSendAmount: BigNumber[];
  runningBalance: BigNumber[];
}

export interface DestinationDistribution {
  leafId: BigNumber;
  chainId: BigNumber;
  amountToReturn: BigNumber;
  l2TokenAddress: string;
  refundAddresses: string[];
  refundAmounts: BigNumber[];
}

export async function buildPoolRebalanceTree(poolRebalances: PoolRebalance[]) {
  for (let i = 0; i < poolRebalances.length; i++) {
    // The 4 provided parallel arrays must be of equal length.
    expect(poolRebalances[i].l1Token.length)
      .to.equal(poolRebalances[i].bundleLpFees.length)
      .to.equal(poolRebalances[i].netSendAmount.length)
      .to.equal(poolRebalances[i].runningBalance.length);
  }

  const paramType = await getParamType("MerkleLib", "verifyPoolRebalance", "rebalance");
  const hashFn = (input: PoolRebalance) => keccak256(defaultAbiCoder.encode([paramType!], [input]));
  return new MerkleTree<PoolRebalance>(poolRebalances, hashFn);
}

export function buildPoolRebalanceLeafs(
  destinationChainIds: number[],
  l1Tokens: Contract[],
  bundleLpFees: BigNumber[][],
  netSendAmounts: BigNumber[][],
  runningBalances: BigNumber[][]
): PoolRebalance[] {
  return Array(destinationChainIds.length)
    .fill(0)
    .map((_, i) => {
      return {
        leafId: BigNumber.from(i),
        chainId: BigNumber.from(destinationChainIds[i]),
        l1Token: l1Tokens.map((token: Contract) => token.address),
        bundleLpFees: bundleLpFees[i],
        netSendAmount: netSendAmounts[i],
        runningBalance: runningBalances[i],
      };
    });
}
