import { expect } from "chai";
import { getParamType, toBNWei } from "./utils";
import { merkleLibFixture } from "./MerkleLib.Fixture";
import { MerkleTree } from "../utils/MerkleTree";
import { repaymentChainId } from "./constants";
import { ethers } from "hardhat";
const { defaultAbiCoder, keccak256 } = ethers.utils;
import { BigNumber, Signer, Contract } from "ethers";

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

export async function constructSimple1ChainTree(token: Contract, scalingSize = 1) {
  const tokensSendToL2 = toBNWei(100 * scalingSize);
  const realizedLpFees = toBNWei(10 * scalingSize);
  const leafs = buildPoolRebalanceLeafs(
    [repaymentChainId], // repayment chain. In this test we only want to send one token to one chain.
    [token], // l1Token. We will only be sending 1 token to one chain.
    [[realizedLpFees]], // bundleLpFees.
    [[tokensSendToL2]], // netSendAmounts.
    [[tokensSendToL2]] // runningBalances.
  );
  const tree = await buildPoolRebalanceTree(leafs);

  return { tokensSendToL2, realizedLpFees, leafs, tree };
}
