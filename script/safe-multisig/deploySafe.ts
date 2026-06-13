#!/usr/bin/env ts-node

import "dotenv/config";
import * as fs from "fs";
import * as path from "path";
import Safe, { ContractNetworksConfig, PredictedSafeProps, SafeAccountConfig } from "@safe-global/protocol-kit";
import { getAddress } from "ethers/lib/utils";
import { ethers } from "../../utils/utils";
import { getNodeUrl } from "../../utils";
import { getChainId, getProvider, getSigner } from "../../scripts/utils";
import { writeMultisigBroadcastArtifact } from "./broadcast";

const DEFAULT_CONFIG_PATH = path.resolve(__dirname, "config.json");
const CANONICAL_INFRA_PATH = path.resolve(__dirname, "canonicalSafeInfraAddresses.json");

interface MultisigConfig {
  owners: string[];
  threshold: number;
  saltNonce: string;
}

function getArg(flag: string): string | undefined {
  const index = process.argv.indexOf(flag);
  return index >= 0 ? process.argv[index + 1] : undefined;
}

function loadMultisigConfig(configPath: string): MultisigConfig {
  const parsed = JSON.parse(fs.readFileSync(configPath, "utf8")) as Partial<MultisigConfig>;
  const owners = parsed.owners;
  const threshold = parsed.threshold;
  const saltNonce = parsed.saltNonce;

  if (!Array.isArray(owners) || owners.length === 0) throw new Error(`Multisig config must include owners`);
  if (typeof threshold !== "number") throw new Error(`Multisig config must include threshold`);
  if (typeof saltNonce !== "string" || !saltNonce) throw new Error(`Multisig config must include saltNonce`);
  if (threshold < 1 || threshold > owners.length) {
    throw new Error(`Threshold ${threshold} is invalid for ${owners.length} owners`);
  }

  const normalizedOwners = owners.map((owner) => getAddress(owner));
  if (new Set(normalizedOwners).size !== normalizedOwners.length) {
    throw new Error(`Multisig config contains duplicate owners`);
  }

  return {
    owners: normalizedOwners,
    threshold,
    saltNonce,
  };
}

function printUsage(): void {
  console.log(`Usage: yarn ts-node ./script/safe-multisig/deploySafe.ts --chain-id <id> [--use-canonical-infra]

Options:
  --use-canonical-infra  Resolve Safe contract addresses from canonicalSafeInfraAddresses.json
                         instead of the safe-deployments registry bundled with protocol-kit.
                         Required for chains the registry does not know (e.g. Arc, 5042).

Reads env vars from .env automatically.

Required env vars:
  MNEMONIC   BIP-39 mnemonic for the deployer wallet
  NODE_URL_<chainId> or CUSTOM_NODE_URL for the selected chain
`);
}

async function resolveChainContext(): Promise<{
  chainId: number;
  provider: ethers.providers.JsonRpcProvider;
  nodeUrl: string;
}> {
  const explicitChainId = getArg("--chain-id");
  if (!explicitChainId) throw new Error("--chain-id is required");
  const chainId = Number(explicitChainId);
  if (!Number.isInteger(chainId) || chainId <= 0) throw new Error(`Invalid --chain-id value: ${explicitChainId}`);
  const nodeUrl = getNodeUrl(chainId);
  const provider = getProvider(nodeUrl);
  const runtimeChainId = await getChainId(provider);
  if (runtimeChainId !== chainId) {
    throw new Error(`RPC ${nodeUrl} reported chain ID ${runtimeChainId}, but --chain-id was ${chainId}`);
  }
  return { chainId, provider, nodeUrl };
}

// Loads the canonical Safe v1.4.1 infra addresses for chains missing from the safe-deployments
// registry bundled with @safe-global/protocol-kit. The SafeL2 singleton is used to match
// protocol-kit's default on other L2 chains, so the deployment calldata and CREATE2 address match
// the Safes deployed there with the same owners/threshold/saltNonce. Every address is required to
// have code on the target chain.
async function loadCanonicalContractNetworks(
  chainId: number,
  provider: ethers.providers.JsonRpcProvider
): Promise<ContractNetworksConfig> {
  const addresses = JSON.parse(fs.readFileSync(CANONICAL_INFRA_PATH, "utf8")) as Record<string, string>;
  await Promise.all(
    Object.entries(addresses).map(async ([name, address]) => {
      if ((await provider.getCode(address)) === "0x") {
        throw new Error(`Canonical Safe contract ${name} has no code at ${address} on chain ${chainId}`);
      }
    })
  );
  return { [chainId]: addresses };
}

function assertSameOwners(actualOwners: string[], expectedOwners: string[]): void {
  const actual = actualOwners.map((owner) => owner.toLowerCase());
  const expected = expectedOwners.map((owner) => owner.toLowerCase());
  if (actual.length !== expected.length || actual.some((owner, index) => owner !== expected[index])) {
    throw new Error(
      `Existing Safe owners ${actualOwners.join(",")} do not match config owners ${expectedOwners.join(",")}`
    );
  }
}

async function main() {
  if (process.argv.includes("--help")) {
    printUsage();
    return;
  }

  const configPath = DEFAULT_CONFIG_PATH;
  const useCanonicalInfra = process.argv.includes("--use-canonical-infra");
  const { chainId, provider, nodeUrl } = await resolveChainContext();
  const config = loadMultisigConfig(configPath);
  const contractNetworks = useCanonicalInfra ? await loadCanonicalContractNetworks(chainId, provider) : undefined;
  const wallet = getSigner(provider);
  const privateKey = wallet._signingKey().privateKey;

  const safeAccountConfig: SafeAccountConfig = {
    owners: config.owners,
    threshold: config.threshold,
  };
  const predictedSafe: PredictedSafeProps = {
    safeAccountConfig,
    safeDeploymentConfig: {
      saltNonce: config.saltNonce,
    },
  };

  console.log(`Connected to chain ${chainId} via ${nodeUrl}`);
  console.log(`Config: ${configPath}`);
  console.log(`Owners: ${config.owners.join(", ")}`);
  console.log(`Threshold: ${config.threshold}`);
  console.log(`Salt nonce: ${config.saltNonce}`);
  console.log(`Safe contract addresses: ${useCanonicalInfra ? CANONICAL_INFRA_PATH : "protocol-kit registry"}`);

  const protocolKit = await Safe.init({
    provider: nodeUrl,
    signer: privateKey,
    predictedSafe,
    contractNetworks,
  });

  const safeAddress = await protocolKit.getAddress();
  if (await protocolKit.isSafeDeployed()) {
    const existingProtocolKit = await protocolKit.connect({ safeAddress });
    const safeOwners = await existingProtocolKit.getOwners();
    const safeThreshold = await existingProtocolKit.getThreshold();
    assertSameOwners(safeOwners, config.owners);
    if (safeThreshold !== config.threshold) {
      throw new Error(`Existing Safe threshold ${safeThreshold} does not match config threshold ${config.threshold}`);
    }
    console.log(`Safe already exists at ${safeAddress}`);
    return;
  }

  console.log(`Deploying Safe at deterministic address ${safeAddress}`);
  const deploymentTransaction = await protocolKit.createSafeDeploymentTransaction();
  if (!deploymentTransaction.to) throw new Error("Safe deployment transaction is missing target address");
  if (!deploymentTransaction.data) throw new Error("Safe deployment transaction is missing calldata");

  const sentTransaction = await wallet.sendTransaction({
    to: deploymentTransaction.to,
    data: deploymentTransaction.data,
    value: deploymentTransaction.value.toString(),
  });
  const receipt = await sentTransaction.wait();
  if (!receipt || receipt.status !== 1) {
    throw new Error(`Safe deployment failed: ${sentTransaction.hash}`);
  }

  const broadcastPath = writeMultisigBroadcastArtifact({
    chainId,
    contractAddress: safeAddress,
    deploymentTransaction: {
      to: deploymentTransaction.to,
      data: deploymentTransaction.data,
      value: deploymentTransaction.value.toString(),
    },
    sentTransaction,
    receipt,
    args: [config.owners, config.threshold, config.saltNonce],
  });

  console.log(`Safe deployed at ${safeAddress}`);
  console.log(`Transaction hash: ${receipt.transactionHash}`);
  console.log(`Broadcast: ${broadcastPath}`);
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
