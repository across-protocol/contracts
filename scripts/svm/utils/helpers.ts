import { utils as anchorUtils, BN } from "@coral-xyz/anchor";
import { relayerRefundHashFn, RelayerRefundLeafSolana, RelayerRefundLeafType } from "../../../test/svm/utils";
import { BigNumber, ethers } from "ethers";
import { PublicKey } from "@solana/web3.js";
import { MerkleTree } from "@uma/common";

export const fromBase58ToBytes32 = (input: string): string => {
  const decodedBytes = anchorUtils.bytes.bs58.decode(input);
  return "0x" + Buffer.from(decodedBytes).toString("hex");
};

export const fromBytes32ToAddress = (input: string): string => {
  // Remove the '0x' prefix if present
  const hexString = input.startsWith("0x") ? input.slice(2) : input;

  // Ensure the input is 64 characters long (32 bytes)
  if (hexString.length !== 64) {
    throw new Error("Invalid bytes32 string");
  }

  // Get the last 40 characters (20 bytes) for the address
  const address = hexString.slice(-40);

  return "0x" + address;
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
  return new MerkleTree<RelayerRefundLeafType>(relayerRefundLeaves, relayerRefundHashFn);
};
