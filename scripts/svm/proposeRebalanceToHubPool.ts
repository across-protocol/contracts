/**
 * Script: Propose Root Bundle for USDC Rebalance to Hub Pool
 *
 * Submits a root bundle proposal on the Hub Pool to rebalance USDC
 * from the Solana Spoke Pool to the Ethereum Hub Pool. After submission
 * and the liveness period, the rebalance can be executed with
 * `executeRebalanceToHubPool.ts`.
 *
 * Required Environment Variables:
 * - TESTNET: (Optional) Set to "true" to use Sepolia; defaults to mainnet.
 * - MNEMONIC: Wallet mnemonic to sign the Ethereum transaction.
 * - HUB_POOL_ADDRESS: Ethereum address of the Hub Pool.
 * - NODE_URL_1: Ethereum RPC URL for mainnet (ignored if TESTNET=true).
 * - NODE_URL_11155111: Ethereum RPC URL for Sepolia (ignored if TESTNET=false).
 *
 * Required Argument:
 * - `--netSendAmount`: The unscaled amount of USDC to rebalance.
 *   (e.g., for USDC with 6 decimals, 1 = 0.000001 USDC).
 *
 * Example Usage:
 * TESTNET=true \
 * NODE_URL_11155111=$NODE_URL_11155111 \
 * MNEMONIC=$MNEMONIC \
 * HUB_POOL_ADDRESS=$HUB_POOL_ADDRESS \
 * anchor run proposeRebalanceToHubPool -- --netSendAmount 7
 *
 * Note:
 * Ensure the required environment variables are set before running this script.
 */

import { PublicKey } from "@solana/web3.js";
import { getNodeUrl } from "@uma/common";
import { BigNumber, ethers } from "ethers";
import yargs from "yargs";
import { hideBin } from "yargs/helpers";
import { BondToken__factory, HubPool__factory } from "../../typechain";
import { CHAIN_IDs } from "../../utils/constants";
import { SOLANA_USDC_DEVNET, SOLANA_USDC_MAINNET } from "./utils/constants";
import {
  constructEmptyPoolRebalanceTree,
  constructSimpleRebalanceTreeToHubPool,
  formatUsdc,
  getSolanaChainId,
  requireEnv,
} from "./utils/helpers";

// Set up Ethereum provider and signer.
const nodeURL = process.env.TESTNET === "true" ? getNodeUrl("sepolia", true) : getNodeUrl("mainnet", true);
const ethersProvider = new ethers.providers.JsonRpcProvider(nodeURL);
const ethersSigner = ethers.Wallet.fromMnemonic(requireEnv("MNEMONIC")).connect(ethersProvider);

// Get the HubPool contract instance.
const hubPoolAddress = ethers.utils.getAddress(requireEnv("HUB_POOL_ADDRESS"));
const hubPool = HubPool__factory.connect(hubPoolAddress, ethersProvider);

// Parse arguments.
const argv = yargs(hideBin(process.argv)).option("netSendAmount", {
  type: "string",
  demandOption: true,
  describe: "Net send amount to Hub Pool from Solana Spoke Pool",
}).argv;

async function proposeRebalanceToHubPool(): Promise<void> {
  const resolvedArgv = await argv;
  const netSendAmount = BigNumber.from(resolvedArgv.netSendAmount);

  // Resolve chain IDs and USDC address.
  const evmChainId = (await ethersProvider.getNetwork()).chainId;
  if (evmChainId !== CHAIN_IDs.MAINNET && evmChainId !== CHAIN_IDs.SEPOLIA) {
    throw new Error("Unsupported EVM chain ID");
  }

  // If evmChainId is mainnet, use mainnet solana cluster. Otherwise, use devnet.
  const solanaCluster = evmChainId === CHAIN_IDs.MAINNET ? "mainnet" : "devnet";
  const solanaChainId = getSolanaChainId(solanaCluster);
  const svmUsdc = evmChainId === CHAIN_IDs.MAINNET ? SOLANA_USDC_MAINNET : SOLANA_USDC_DEVNET;

  // Check there are no active proposals.
  const currentRootBundleProposal = await hubPool.callStatic.rootBundleProposal();
  if (currentRootBundleProposal.unclaimedPoolRebalanceLeafCount !== 0) {
    throw new Error("Proposal has unclaimed leaves");
  }

  // Ensure bond token balance and approval is sufficient.
  const bondTokenAddress = await hubPool.callStatic.bondToken();
  const bondAmount = await hubPool.callStatic.bondAmount();
  const bondToken = BondToken__factory.connect(bondTokenAddress, ethersProvider);
  const bondBalance = await bondToken.callStatic.balanceOf(ethersSigner.address);
  if (bondBalance.lt(bondAmount)) {
    const ethDeposit = bondAmount.sub(bondBalance);
    console.log(`Depositing ${ethers.utils.formatUnits(ethDeposit.toString())} ETH into bond token:`);
    const tx = await bondToken.connect(ethersSigner).deposit({ value: ethDeposit });
    console.log(`✅ submitted tx hash: ${tx.hash}`);
    await tx.wait();
    console.log("✅ tx confirmed");
  }
  const allowance = await bondToken.callStatic.allowance(ethersSigner.address, hubPool.address);
  if (allowance.lt(bondAmount)) {
    console.log(`Approving ${ethers.utils.formatUnits(bondAmount.toString())} bond tokens for HubPool:`);
    const tx = await bondToken.connect(ethersSigner).approve(hubPool.address, bondAmount);
    console.log(`✅ submitted tx hash: ${tx.hash}`);
    await tx.wait();
    console.log("✅ tx confirmed");
  }

  // Construct an empty pool rebalance tree as we need to propose at least one leaf.
  const { poolRebalanceTree } = constructEmptyPoolRebalanceTree(solanaChainId, 0);
  // Relayer refund root Merkle tree.
  const { merkleTree } = constructSimpleRebalanceTreeToHubPool(netSendAmount, solanaChainId, new PublicKey(svmUsdc));

  console.log("Proposing rebalance pool bundle to spoke...");
  console.table([
    { Property: "isTestnet", Value: process.env.TESTNET === "true" },
    { Property: "originChainId", Value: evmChainId.toString() },
    { Property: "targetChainId", Value: solanaChainId.toString() },
    { Property: "hubPoolAddress", Value: hubPool.address },
    { Property: "netSendAmount (formatted)", Value: formatUsdc(netSendAmount) },
    { Property: "poolRebalanceRoot", Value: poolRebalanceTree.getHexRoot() },
    { Property: "relayerRefundRoot", Value: merkleTree.getHexRoot() },
  ]);

  console.log("Submitting proposal...");
  const tx = await hubPool.connect(ethersSigner).proposeRootBundle(
    [0], // bundleEvaluationBlockNumbers, not checked in this script.
    1, // poolRebalanceLeafCount, only one leaf in this script.
    poolRebalanceTree.getHexRoot(), // poolRebalanceRoot.
    merkleTree.getHexRoot(), // relayerRefundRoot.
    ethers.constants.HashZero // slowRelayRoot.
  );

  await tx.wait();
  console.log("✅ proposal submitted");
}

// Run the proposeRebalanceToHubPool function.
proposeRebalanceToHubPool();
