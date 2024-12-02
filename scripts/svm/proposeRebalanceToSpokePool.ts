import * as crypto from "crypto";
// eslint-disable-next-line camelcase
import { CHAIN_IDs, TOKEN_SYMBOLS_MAP } from "../../utils/constants";
import yargs from "yargs";
import { hideBin } from "yargs/helpers";
import { ethers, BigNumber } from "ethers";
// eslint-disable-next-line camelcase
import { BondToken__factory, HubPool__factory } from "../../typechain";
import { MerkleTree } from "@uma/common";

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

// Parse arguments
const argv = yargs(hideBin(process.argv)).option("netSendAmount", {
  type: "string",
  demandOption: true,
  describe: "Net send amount to spoke",
}).argv;

async function rebalanceToSpokePool(): Promise<void> {
  const resolvedArgv = await argv;
  const netSendAmount = BigNumber.from(resolvedArgv.netSendAmount);

  // Resolve chain IDs and USDC address.
  const evmChainId = (await ethersProvider.getNetwork()).chainId;
  if (evmChainId !== CHAIN_IDs.MAINNET && evmChainId !== CHAIN_IDs.SEPOLIA) throw new Error("Unsupported EVM chain ID");
  const solanaCluster = evmChainId === CHAIN_IDs.MAINNET ? "mainnet" : "devnet";
  const solanaChainId = BigNumber.from(
    BigInt(ethers.utils.keccak256(ethers.utils.toUtf8Bytes(`solana-${solanaCluster}`))) & BigInt("0xFFFFFFFFFFFFFFFF")
  );
  const l1TokenAddress = TOKEN_SYMBOLS_MAP.USDC.addresses[evmChainId];

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

  // Construct the merkle tree for the pool rebalance.
  const poolRebalanceLeaves = [
    {
      chainId: solanaChainId,
      groupIndex: BigNumber.from(1), // Not 0 as this script is not relaying root bundles, only sending tokens to spoke.
      bundleLpFees: [BigNumber.from(0)],
      netSendAmounts: [netSendAmount],
      runningBalances: [netSendAmount],
      leafId: BigNumber.from(0),
      l1Tokens: [l1TokenAddress],
    },
  ];
  const paramType =
    "tuple( uint256 chainId, uint256[] bundleLpFees, int256[] netSendAmounts, int256[] runningBalances, uint256 groupIndex, uint8 leafId, address[] l1Tokens )";
  const hashFn = (input: any) => ethers.utils.keccak256(ethers.utils.defaultAbiCoder.encode([paramType], [input]));
  const tree = new MerkleTree(poolRebalanceLeaves, hashFn);

  // Propose the rebalance to the spoke pool.
  console.log("Proposing rebalance to spoke pool:");
  const tx = await hubPool.connect(ethersSigner).proposeRootBundle(
    [0], // bundleEvaluationBlockNumbers, not checked in this script.
    poolRebalanceLeaves.length, // poolRebalanceLeafCount.
    tree.getHexRoot(), // poolRebalanceRoot. Generated from the merkle tree constructed before.
    crypto.randomBytes(32), // relayerRefundRoot, not relevant for this script.
    crypto.randomBytes(32) // slowRelayRoot, not relevant for this test.
  );
  console.log(`✔️ submitted tx hash: ${tx.hash}`);
  await tx.wait();
  console.log(`✔️ tx confirmed`);
}

// Run the rebalanceToSpokePool function
rebalanceToSpokePool();
