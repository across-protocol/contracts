import { BigNumber, ethers } from "ethers";
import yargs from "yargs";
import { hideBin } from "yargs/helpers";
import { CHAIN_IDs, TOKEN_SYMBOLS_MAP } from "../../utils/constants";
import { PublicKey } from "@solana/web3.js";
import { BondToken__factory, HubPool__factory } from "../../typechain";
import { SOLANA_USDC_DEVNET, SOLANA_USDC_MAINNET } from "./utils/constants";
import { constructEmptyPoolRebalanceTree, constructSimpleRebalanceTreeToHubPool } from "./utils/helpers";

// Set up Ethereum provider.
if (!process.env.ETHERS_PROVIDER_URL) {
  throw new Error("Environment variable ETHERS_PROVIDER_URL is not set");
}
const ethersProvider = new ethers.providers.JsonRpcProvider(process.env.ETHERS_PROVIDER_URL);

if (!process.env.ETHERS_MNEMONIC) {
  throw new Error("Environment variable ETHERS_MNEMONIC is not set");
}
const ethersSigner = ethers.Wallet.fromMnemonic(process.env.ETHERS_MNEMONIC).connect(ethersProvider);

// Get the HubPool contract instance.
if (!process.env.HUB_POOL_ADDRESS) {
  throw new Error("Environment variable HUB_POOL_ADDRESS is not set");
}
const hubPoolAddress = ethers.utils.getAddress(process.env.HUB_POOL_ADDRESS);
const hubPool = HubPool__factory.connect(hubPoolAddress, ethersProvider);

// Parse arguments.
const argv = yargs(hideBin(process.argv)).option("netSendAmount", {
  type: "string",
  demandOption: true,
  describe: "Net send amount to spoke",
}).argv;

async function proposeRebalanceToHubPool(): Promise<void> {
  const resolvedArgv = await argv;
  const netSendAmount = BigNumber.from(resolvedArgv.netSendAmount);

  // Resolve chain IDs and USDC address.
  const evmChainId = (await ethersProvider.getNetwork()).chainId;
  if (evmChainId !== CHAIN_IDs.MAINNET && evmChainId !== CHAIN_IDs.SEPOLIA) {
    throw new Error("Unsupported EVM chain ID");
  }
  const solanaCluster = evmChainId === CHAIN_IDs.MAINNET ? "mainnet" : "devnet";
  const solanaChainId = BigNumber.from(
    BigInt(ethers.utils.keccak256(ethers.utils.toUtf8Bytes(`solana-${solanaCluster}`))) & BigInt("0xFFFFFFFFFFFFFFFF")
  );
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
    console.log(`✔️ submitted tx hash: ${tx.hash}`);
    await tx.wait();
    console.log("✔️ tx confirmed");
  }
  const allowance = await bondToken.callStatic.allowance(ethersSigner.address, hubPool.address);
  if (allowance.lt(bondAmount)) {
    console.log(`Approving ${ethers.utils.formatUnits(bondAmount.toString())} bond tokens for HubPool:`);
    const tx = await bondToken.connect(ethersSigner).approve(hubPool.address, bondAmount);
    console.log(`✔️ submitted tx hash: ${tx.hash}`);
    await tx.wait();
    console.log("✔️ tx confirmed");
  }

  const l1TokenAddress = TOKEN_SYMBOLS_MAP.USDC.addresses[evmChainId];

  // Construct simple Merkle tree for the pool rebalance.
  const { poolRebalanceTree } = constructEmptyPoolRebalanceTree(solanaChainId, 0);

  console.log("Proposing rebalance pool bundle to spoke...");
  console.table([
    { Property: "originChainId", Value: evmChainId.toString() },
    { Property: "targetChainId", Value: solanaChainId.toString() },
    { Property: "hubPoolAddress", Value: hubPool.address },
    { Property: "l1TokenAddress", Value: l1TokenAddress },
    { Property: "netSendAmount", Value: netSendAmount.toString() },
    { Property: "poolRebalanceRoot", Value: poolRebalanceTree.getHexRoot() },
  ]);

  // Relayer refund root Merkle tree.
  const merkleTree = constructSimpleRebalanceTreeToHubPool(netSendAmount, solanaChainId, new PublicKey(svmUsdc));

  console.log(`Proposing ${netSendAmount.toString()} rebalance to hub pool:`);
  const tx = await hubPool.connect(ethersSigner).proposeRootBundle(
    [0], // bundleEvaluationBlockNumbers, not checked in this script.
    1, // poolRebalanceLeafCount.
    poolRebalanceTree.getHexRoot(), // poolRebalanceRoot.
    merkleTree.getHexRoot(), // relayerRefundRoot.
    ethers.constants.HashZero // slowRelayRoot.
  );
  console.log(`✔️ submitted tx hash: ${tx.hash}`);
  await tx.wait();
  console.log("✔️ tx confirmed");
}

// Run the proposeRebalanceToHubPool function.
proposeRebalanceToHubPool();
