import { expect } from "chai";
import { getParamType } from "./utils";
import { MerkleTree } from "../utils/MerkleTree";
import { ethers } from "hardhat";
const { defaultAbiCoder, keccak256 } = ethers.utils;
import { BigNumber, Contract } from "ethers";

export interface PoolRebalance {
  leafId: BigNumber;
  chainId: BigNumber;
  l1Tokens: string[];
  bundleLpFees: BigNumber[];
  netSendAmounts: BigNumber[];
  runningBalances: BigNumber[];
}

export interface DestinationDistribution {
  leafId: BigNumber;
  chainId: BigNumber;
  amountToReturn: BigNumber;
  l2TokenAddress: string;
  refundAddresses: string[];
  refundAmounts: BigNumber[];
}

export async function buildDestinationDistributionTree(destinationDistributions: DestinationDistribution[]) {
  for (let i = 0; i < destinationDistributions.length; i++) {
    // The 2 provided parallel arrays must be of equal length.
    expect(destinationDistributions[i].refundAddresses.length).to.equal(
      destinationDistributions[i].refundAmounts.length
    );
  }

  const paramType = await getParamType("MerkleLib", "verifyRelayerDistribution", "distribution");
  const hashFn = (input: DestinationDistribution) => keccak256(defaultAbiCoder.encode([paramType!], [input]));
  return new MerkleTree<DestinationDistribution>(destinationDistributions, hashFn);
}

export function buildDestinationDistributionLeafs(
  destinationChainIds: number[],
  amountsToReturn: BigNumber[],
  l2Tokens: Contract[],
  refundAddresses: string[][],
  refundAmounts: BigNumber[][]
): DestinationDistribution[] {
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

export async function buildPoolRebalanceTree(poolRebalances: PoolRebalance[]) {
  for (let i = 0; i < poolRebalances.length; i++) {
    // The 4 provided parallel arrays must be of equal length.
    expect(poolRebalances[i].l1Tokens.length)
      .to.equal(poolRebalances[i].bundleLpFees.length)
      .to.equal(poolRebalances[i].netSendAmounts.length)
      .to.equal(poolRebalances[i].runningBalances.length);
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
        l1Tokens: l1Tokens.map((token: Contract) => token.address),
        bundleLpFees: bundleLpFees[i],
        netSendAmounts: netSendAmounts[i],
        runningBalances: runningBalances[i],
      };
    });
}
