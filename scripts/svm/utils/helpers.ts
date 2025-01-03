import { BN } from "@coral-xyz/anchor";
import { PublicKey } from "@solana/web3.js";
import { MerkleTree } from "@uma/common";
import { BigNumber, ethers } from "ethers";
import { relayerRefundHashFn } from "../../../src/svm";
import { RelayerRefundLeafSolana, RelayerRefundLeafType } from "../../../src/types/svm";

export const requireEnv = (name: string): string => {
  if (!process.env[name]) throw new Error(`Environment variable ${name} is not set`);
  return process.env[name];
};

export const formatUsdc = (amount: BigNumber): string => {
  return ethers.utils.formatUnits(amount, 6);
};

export function constructEmptyPoolRebalanceTree(chainId: BigNumber, groupIndex: number) {
  const poolRebalanceLeaf = {
    chainId,
    groupIndex: BigNumber.from(groupIndex),
    bundleLpFees: [],
    netSendAmounts: [],
    runningBalances: [],
    leafId: BigNumber.from(0),
    l1Tokens: [],
  };

  const rebalanceParamType =
    "tuple( uint256 chainId, uint256[] bundleLpFees, int256[] netSendAmounts, int256[] runningBalances, uint256 groupIndex, uint8 leafId, address[] l1Tokens )";
  const rebalanceHashFn = (input: any) =>
    ethers.utils.keccak256(ethers.utils.defaultAbiCoder.encode([rebalanceParamType], [input]));

  const poolRebalanceTree = new MerkleTree([poolRebalanceLeaf], rebalanceHashFn);
  return { poolRebalanceLeaf, poolRebalanceTree };
}

export const constructSimpleRebalanceTreeToHubPool = (
  netSendAmount: BigNumber,
  solanaChainId: BigNumber,
  svmUsdc: PublicKey
) => {
  const relayerRefundLeaves: RelayerRefundLeafSolana[] = [];
  relayerRefundLeaves.push({
    isSolana: true,
    leafId: new BN(0),
    chainId: new BN(solanaChainId.toString()),
    amountToReturn: new BN(netSendAmount.toString()),
    mintPublicKey: new PublicKey(svmUsdc),
    refundAddresses: [],
    refundAmounts: [],
  });
  const merkleTree = new MerkleTree<RelayerRefundLeafType>(relayerRefundLeaves, relayerRefundHashFn);
  return { merkleTree, leaves: relayerRefundLeaves };
};
