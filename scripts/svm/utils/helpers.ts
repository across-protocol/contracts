import { BN } from "@coral-xyz/anchor";
import { PublicKey } from "@solana/web3.js";
import { MerkleTree } from "@uma/common";
import { BigNumber, ethers } from "ethers";
import { relayerRefundHashFn } from "../../../src/svm/web3-v1";
import { RelayerRefundLeafSolana, RelayerRefundLeafType } from "../../../src/types/svm";

// Minimal ABIs for HubPool and BondToken (ERC20-like) contracts used by SVM scripts.
// These replace the typechain-generated factories that were removed with hardhat.

const hubPoolAbi = [
  "function rootBundleProposal() view returns (bytes32 poolRebalanceRoot, bytes32 relayerRefundRoot, bytes32 slowRelayRoot, uint256 claimedBitMap, uint256 unclaimedPoolRebalanceLeafCount, uint256 challengePeriodEndTimestamp)",
  "function executeRootBundle(uint256 chainId, uint256 groupIndex, uint256[] bundleLpFees, int256[] netSendAmounts, int256[] runningBalances, uint8 leafId, address[] l1Tokens, bytes32[] proof)",
  "function proposeRootBundle(uint256[] bundleEvaluationBlockNumbers, uint8 poolRebalanceLeafCount, bytes32 poolRebalanceRoot, bytes32 relayerRefundRoot, bytes32 slowRelayRoot)",
  "function relaySpokePoolAdminFunction(uint256 chainId, bytes calldata functionData)",
  "function bondToken() view returns (address)",
  "function bondAmount() view returns (uint256)",
  "function getCurrentTime() view returns (uint256)",
];

const bondTokenAbi = [
  "function balanceOf(address account) view returns (uint256)",
  "function deposit() payable",
  "function approve(address spender, uint256 amount) returns (bool)",
  "function allowance(address owner, address spender) view returns (uint256)",
];

export function getHubPoolContract(address: string, signerOrProvider: ethers.Signer | ethers.providers.Provider) {
  return new ethers.Contract(address, hubPoolAbi, signerOrProvider);
}

export function getBondTokenContract(address: string, signerOrProvider: ethers.Signer | ethers.providers.Provider) {
  return new ethers.Contract(address, bondTokenAbi, signerOrProvider);
}

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
