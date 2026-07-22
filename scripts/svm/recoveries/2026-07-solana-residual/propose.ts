/**
 * Script: Propose the 2026-07 Solana Residual Recovery Bundle
 *
 * Submits a root bundle proposal on the HubPool with the recovery leaf from `leaf.json` in this
 * directory (direct relayer repayment, amountToReturn 0) and the matching empty pool rebalance
 * leaf. Mirrors `proposeRebalanceToHubPool.ts` but constructs the refund tree from the leaf
 * file instead of a --netSendAmount argument. Mainnet only. Run `verify.ts` first, and
 * coordinate with dataworker/disputer operators before proposing (see README.md).
 *
 * Required Environment Variables:
 * - MNEMONIC: Wallet mnemonic to sign the Ethereum transaction.
 * - HUB_POOL_ADDRESS: Ethereum address of the Hub Pool.
 * - NODE_URL_1: Ethereum RPC URL for mainnet.
 *
 * Example Usage:
 * NODE_URL_1=$NODE_URL_1 \
 * MNEMONIC=$MNEMONIC \
 * HUB_POOL_ADDRESS=$HUB_POOL_ADDRESS \
 * anchor run proposeSolanaResidualRecovery
 */

import { BN } from "@coral-xyz/anchor";
import { PublicKey } from "@solana/web3.js";
import { ethers } from "ethers";
import { readFileSync } from "fs";
import * as path from "path";
import { relayerRefundHashFn } from "../../../../src/svm/web3-v1";
import { RelayerRefundLeafSolana, RelayerRefundLeafType } from "../../../../src/types/svm";
import { CHAIN_IDs, getNodeUrl } from "../../../../utils";
import { MerkleTree } from "../../../../utils/MerkleTree";
import {
  constructEmptyPoolRebalanceTree,
  formatUsdc,
  getBondTokenContract,
  getHubPoolContract,
  requireEnv,
} from "../../utils/helpers";

// Set up Ethereum provider and signer (mainnet only — this is a specific mainnet recovery).
const ethersProvider = new ethers.providers.JsonRpcProvider(getNodeUrl(CHAIN_IDs.MAINNET));
const ethersSigner = ethers.Wallet.fromMnemonic(requireEnv("MNEMONIC")).connect(ethersProvider);
const hubPool = getHubPoolContract(ethers.utils.getAddress(requireEnv("HUB_POOL_ADDRESS")), ethersProvider);

async function proposeSolanaResidualRecovery(): Promise<void> {
  const expected = JSON.parse(readFileSync(path.join(__dirname, "leaf.json"), "utf8"));
  if ((await ethersProvider.getNetwork()).chainId !== CHAIN_IDs.MAINNET) throw new Error("Mainnet only");

  // Construct both trees from the leaf file and check them against the declared roots.
  const solanaChainId = ethers.BigNumber.from(expected.leaf.chainId);
  const leaf: RelayerRefundLeafSolana = {
    isSolana: true,
    leafId: new BN(expected.leaf.leafId),
    chainId: new BN(expected.leaf.chainId),
    amountToReturn: new BN(expected.leaf.amountToReturn),
    mintPublicKey: new PublicKey(expected.leaf.mintPublicKey),
    refundAddresses: expected.leaf.refundAddresses.map((a: string) => new PublicKey(a)),
    refundAmounts: expected.leaf.refundAmounts.map((a: string) => new BN(a)),
  };
  const merkleTree = new MerkleTree<RelayerRefundLeafType>([leaf], relayerRefundHashFn);
  const { poolRebalanceTree } = constructEmptyPoolRebalanceTree(solanaChainId, 0);
  if (
    merkleTree.getHexRoot() !== expected.relayerRefundRoot ||
    poolRebalanceTree.getHexRoot() !== expected.poolRebalanceRoot
  )
    throw new Error("Recomputed roots do not match leaf.json — run verify.ts");

  // Check there are no active proposals.
  const currentRootBundleProposal = await hubPool.callStatic.rootBundleProposal();
  if (currentRootBundleProposal.unclaimedPoolRebalanceLeafCount !== 0) throw new Error("Proposal has unclaimed leaves");

  // Ensure bond token balance and approval is sufficient.
  const bondTokenAddress = await hubPool.callStatic.bondToken();
  const bondAmount = await hubPool.callStatic.bondAmount();
  const bondToken = getBondTokenContract(bondTokenAddress, ethersProvider);
  const bondBalance = await bondToken.callStatic.balanceOf(ethersSigner.address);
  if (bondBalance.lt(bondAmount)) {
    const ethDeposit = bondAmount.sub(bondBalance);
    console.log(`Depositing ${ethers.utils.formatUnits(ethDeposit.toString())} ETH into bond token:`);
    const tx = await bondToken.connect(ethersSigner).deposit({ value: ethDeposit });
    console.log(`✅ submitted tx hash: ${tx.hash}`);
    await tx.wait();
  }
  const allowance = await bondToken.callStatic.allowance(ethersSigner.address, hubPool.address);
  if (allowance.lt(bondAmount)) {
    console.log(`Approving ${ethers.utils.formatUnits(bondAmount.toString())} bond tokens for HubPool:`);
    const tx = await bondToken.connect(ethersSigner).approve(hubPool.address, bondAmount);
    console.log(`✅ submitted tx hash: ${tx.hash}`);
    await tx.wait();
  }

  console.log("Proposing the recovery bundle...");
  console.table([
    { Property: "hubPoolAddress", Value: hubPool.address },
    { Property: "targetChainId", Value: solanaChainId.toString() },
    { Property: "refundAddresses", Value: expected.leaf.refundAddresses.join(", ") },
    {
      Property: "refundAmounts (formatted)",
      Value: expected.leaf.refundAmounts.map((a: string) => formatUsdc(ethers.BigNumber.from(a))).join(", "),
    },
    { Property: "poolRebalanceRoot", Value: poolRebalanceTree.getHexRoot() },
    { Property: "relayerRefundRoot", Value: merkleTree.getHexRoot() },
  ]);

  const tx = await hubPool.connect(ethersSigner).proposeRootBundle(
    [0], // bundleEvaluationBlockNumbers, not checked in this script.
    1, // poolRebalanceLeafCount, only one leaf in this script.
    poolRebalanceTree.getHexRoot(),
    merkleTree.getHexRoot(),
    ethers.constants.HashZero // slowRelayRoot.
  );
  await tx.wait();
  console.log(`✅ proposal submitted: ${tx.hash}`);
}

proposeSolanaResidualRecovery();
