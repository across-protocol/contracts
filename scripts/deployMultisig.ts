import { getNodeUrl } from "../utils";
import { ethers } from "../utils/utils";
import { hre } from "../utils/utils.hre";
import Safe, { SafeAccountConfig, PredictedSafeProps } from "@safe-global/protocol-kit";

const safeAccountConfig: SafeAccountConfig = {
  owners: [
    "0x868CF19464e17F76D6419ACC802B122c22D2FD34",
    "0xcc400c09ecBAC3e0033e4587BdFAABB26223e37d",
    "0x837219D7a9C666F5542c4559Bf17D7B804E5c5fe",
    "0x1d933Fd71FF07E69f066d50B39a7C34EB3b69F05",
    "0x996267d7d1B7f5046543feDe2c2Db473Ed4f65e9",
  ],
  threshold: 2,
};
const EXPECTED_SAFE_ADDRESS = "0x0Fc8E2BB9bEd4FDb51a0d36f2415c4C7F9e75F6e";
const predictedSafe: PredictedSafeProps = {
  safeAccountConfig,
  safeDeploymentConfig: {
    // Safe addresses are deterministic based on owners and salt nonce.
    saltNonce: "0x1234",
  },
};

/**
 * Script to deploy a new Safe Multisig contract via the Safe SDK. Run via:
 * ```
 * yarn hardhat run ./scripts/deployMultisig.ts \
 * --network hyperevm \
 * ```
 */
async function main() {
  const chainId = parseInt(await hre.getChainId());
  const nodeUrl = getNodeUrl(chainId);
  const wallet = ethers.Wallet.fromMnemonic((hre.network.config.accounts as any).mnemonic);
  const privateKey = wallet._signingKey().privateKey;
  console.log(`Connected to node ${nodeUrl} for chain ${chainId}`);
  const signer = wallet.connect(new ethers.providers.JsonRpcProvider(nodeUrl));

  const protocolKit = await Safe.init({
    provider: nodeUrl,
    signer: privateKey,
    predictedSafe,
  });

  // Check if the safe already exists:
  const existingProtocolKit = await protocolKit.connect({
    safeAddress: EXPECTED_SAFE_ADDRESS,
  });
  const isDeployed = await existingProtocolKit.isSafeDeployed();
  if (isDeployed) {
    const safeAddress = await existingProtocolKit.getAddress();
    const safeOwners = await existingProtocolKit.getOwners();
    const safeThreshold = await existingProtocolKit.getThreshold();
    console.log(`Safe already exists at ${EXPECTED_SAFE_ADDRESS}:`, {
      safeAddress,
      safeOwners,
      safeThreshold,
    });
    return;
  }

  // Deploy a new safe:
  const safeAddress = await protocolKit.getAddress();
  if (safeAddress !== EXPECTED_SAFE_ADDRESS) {
    throw new Error(`Safe address ${safeAddress} does not match expected ${EXPECTED_SAFE_ADDRESS}`);
  }
  console.log(`Deploying a new safe with determinstic address: ${safeAddress}`);
  const deploymentTransaction = await protocolKit.createSafeDeploymentTransaction();
  console.log(`Deployment txn data`, deploymentTransaction);
  const client = await protocolKit.getSafeProvider().getExternalSigner();
  if (!client) {
    throw new Error("Unable to get external signer from safe provider");
  }
  const deployerAccount = client.account.address;
  console.log(`Deployer account: ${deployerAccount}`);
  const clientConnectedChain = client.chain;
  if (client.chain?.id !== chainId) {
    throw new Error(`Client connected to chain ${clientConnectedChain?.id}, but expected ${chainId}`);
  }
  if (deploymentTransaction.value.toString() !== "0") {
    throw new Error(`Deployment transaction value should be 0, but is ${deploymentTransaction.value}`);
  }
  console.log(`Sending deployment transaction...`);
  const txnHash = await signer.sendTransaction({
    to: deploymentTransaction.to,
    value: 0,
    data: deploymentTransaction.data,
  });
  const txnReceipt = await txnHash.wait();
  console.log(`Success! Deployment transaction receipt:`, txnReceipt);
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
