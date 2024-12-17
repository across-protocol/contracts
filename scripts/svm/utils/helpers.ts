import { utils as anchorUtils, BN, AnchorProvider } from "@coral-xyz/anchor";
import { BigNumber, ethers } from "ethers";
import { PublicKey } from "@solana/web3.js";
import { MerkleTree } from "@uma/common";
import { RelayerRefundLeafSolana, RelayerRefundLeafType } from "../../../src/types/svm";
import { relayerRefundHashFn } from "../../../src/svm";

export const requireEnv = (name: string): string => {
  if (!process.env[name]) throw new Error(`Environment variable ${name} is not set`);
  return process.env[name];
};

export const getSolanaChainId = (cluster: "devnet" | "mainnet"): BigNumber => {
  return BigNumber.from(
    BigInt(ethers.utils.keccak256(ethers.utils.toUtf8Bytes(`solana-${cluster}`))) & BigInt("0xFFFFFFFFFFFFFFFF")
  );
};

export const isSolanaDevnet = (provider: AnchorProvider): boolean => {
  const solanaRpcEndpoint = provider.connection.rpcEndpoint;
  if (solanaRpcEndpoint.includes("devnet")) return true;
  else if (solanaRpcEndpoint.includes("mainnet")) return false;
  else throw new Error(`Unsupported solanaCluster endpoint: ${solanaRpcEndpoint}`);
};

export const formatUsdc = (amount: BigNumber): string => {
  return ethers.utils.formatUnits(amount, 6);
};

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
  const merkleTree = new MerkleTree<RelayerRefundLeafType>(relayerRefundLeaves, relayerRefundHashFn);
  return { merkleTree, leaves: relayerRefundLeaves };
};
