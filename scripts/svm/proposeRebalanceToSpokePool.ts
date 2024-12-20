// This script proposes root bundle on HubPool that would rebalance tokens to Solana Spoke Pool once executed.
// Required environment:
// - TESTNET: (Optional) Set to "true" to use Sepolia; defaults to mainnet.
// - MNEMONIC: Wallet mnemonic to sign the Ethereum transaction.
// - HUB_POOL_ADDRESS: Hub Pool address
// - NODE_URL_1: Ethereum RPC URL for mainnet (ignored if TESTNET=true).
// - NODE_URL_11155111: Ethereum RPC URL for Sepolia (ignored if TESTNET=false).

// eslint-disable-next-line camelcase
import { getNodeUrl } from "@uma/common";
import { BigNumber, ethers } from "ethers";
import yargs from "yargs";
import { hideBin } from "yargs/helpers";
import { CHAIN_IDs, TOKEN_SYMBOLS_MAP } from "../../utils/constants";
// eslint-disable-next-line camelcase
import { getSolanaChainId } from "../../src/svm";
import { BondToken__factory, HubPool__factory } from "../../typechain";
import { requireEnv } from "./utils/helpers";
import { constructSimpleRebalanceTree } from "./utils/poolRebalanceTree";

// Set up Ethereum provider.
const nodeURL = process.env.TESTNET === "true" ? getNodeUrl("sepolia", true) : getNodeUrl("mainnet", true);
const ethersProvider = new ethers.providers.JsonRpcProvider(nodeURL);
const ethersSigner = ethers.Wallet.fromMnemonic(requireEnv("MNEMONIC")).connect(ethersProvider);

// Get the HubPool contract instance.
const hubPoolAddress = ethers.utils.getAddress(requireEnv("HUB_POOL_ADDRESS"));
const hubPool = HubPool__factory.connect(hubPoolAddress, ethersProvider);

// Parse arguments
const argv = yargs(hideBin(process.argv)).option("netSendAmount", {
  type: "string",
  demandOption: true,
  describe: "Net send amount to spoke",
}).argv;

async function proposeRebalanceToSpokePool(): Promise<void> {
  const resolvedArgv = await argv;
  const netSendAmount = BigNumber.from(resolvedArgv.netSendAmount);

  // Resolve chain IDs and USDC address.
  const evmChainId = (await ethersProvider.getNetwork()).chainId;
  if (evmChainId !== CHAIN_IDs.MAINNET && evmChainId !== CHAIN_IDs.SEPOLIA) throw new Error("Unsupported EVM chain ID");
  const solanaCluster = evmChainId === CHAIN_IDs.MAINNET ? "mainnet" : "devnet";
  const solanaChainId = getSolanaChainId(solanaCluster);
  const l1TokenAddress = TOKEN_SYMBOLS_MAP.USDC.addresses[evmChainId];

  // Construct simple merkle tree for the pool rebalance.
  const { poolRebalanceTree } = constructSimpleRebalanceTree(l1TokenAddress, netSendAmount, solanaChainId);

  console.log("Proposing rebalance pool bundle to spoke...");
  console.table([
    { Property: "originChainId", Value: evmChainId.toString() },
    { Property: "targetChainId", Value: solanaChainId.toString() },
    { Property: "hubPoolAddress", Value: hubPool.address },
    { Property: "l1TokenAddress", Value: l1TokenAddress },
    { Property: "netSendAmount", Value: netSendAmount.toString() },
    { Property: "poolRebalanceRoot", Value: poolRebalanceTree.getHexRoot() },
  ]);

  // Check there are no active proposals.
  const currentRootBundleProposal = await hubPool.callStatic.rootBundleProposal();
  if (currentRootBundleProposal.unclaimedPoolRebalanceLeafCount !== 0) throw new Error("Proposal has unclaimed leaves");

  // Ensure bond token balance and approval is sufficient
  const bondTokenAddress = await hubPool.callStatic.bondToken();
  const bondAmount = await hubPool.callStatic.bondAmount();
  const bondToken = BondToken__factory.connect(bondTokenAddress, ethersProvider);
  const bondBalance = await bondToken.callStatic.balanceOf(ethersSigner.address);
  if (bondBalance.lt(bondAmount)) {
    const ethDeposit = bondAmount.sub(bondBalance);
    console.log(`Depositing ${ethers.utils.formatUnits(ethDeposit.toString())} ETH into bond token:`);
    // This will throw if the signer does not have enough ETH.
    const tx = await bondToken.connect(ethersSigner).deposit({ value: bondAmount.sub(bondBalance) });
    console.log(`✔️ submitted tx hash: ${tx.hash}`);
    await tx.wait();
    console.log(`✔️ tx confirmed`);
  }
  const allowance = await bondToken.callStatic.allowance(ethersSigner.address, hubPool.address);
  if (allowance.lt(bondAmount)) {
    console.log(`Approving ${ethers.utils.formatUnits(bondAmount.toString())} bond tokens for HubPool:`);
    const tx = await bondToken.connect(ethersSigner).approve(hubPool.address, bondAmount);
    console.log(`✔️ submitted tx hash: ${tx.hash}`);
    await tx.wait();
    console.log(`✔️ tx confirmed`);
  }

  // Propose the rebalance to the spoke pool.
  console.log(`Proposing ${netSendAmount.toString()} rebalance to spoke pool:`);
  const tx = await hubPool.connect(ethersSigner).proposeRootBundle(
    [0], // bundleEvaluationBlockNumbers, not checked in this script.
    1, // poolRebalanceLeafCount.
    poolRebalanceTree.getHexRoot(), // poolRebalanceRoot. Generated from the merkle tree constructed before.
    ethers.constants.HashZero, // relayerRefundRoot, not relevant for this script.
    ethers.constants.HashZero // slowRelayRoot, not relevant for this test.
  );
  console.log(`✔️ submitted tx hash: ${tx.hash}`);
  await tx.wait();
  console.log(`✔️ tx confirmed`);

  console.log(
    "Rebalance proposal submitted successfully, to execute, run executeRebalanceToSpokePool script with the same netSendAmount after liveness period."
  );
}

// Run the proposeRebalanceToSpokePool function
proposeRebalanceToSpokePool();
