#!/usr/bin/env ts-node
/**
 * Deploys CounterfactualDepositSpokePool to Tron.
 *
 * Options:
 *   --testnet  — deploy to Tron Nile testnet (default: mainnet)
 *
 * Usage:
 *   yarn tron-deploy-counterfactual-deposit-spokepool <spokePool> <signer> <wrappedNativeToken> [--testnet]
 */

import "dotenv/config";
import * as path from "path";
import { TronWeb } from "tronweb";
import { deployContract, encodeArgs, tronToEvmAddress, resolveChainId } from "../deploy";

function validateAddress(value: string, name: string): void {
  if (!TronWeb.isAddress(value)) {
    console.log(`Error: invalid ${name} "${value}". Expected Tron Base58Check address (T...).`);
    process.exit(1);
  }
}

async function main(): Promise<void> {
  const args = process.argv.slice(2).filter((a) => !a.startsWith("-"));
  const spokePool = args[0];
  const signer = args[1];
  const wrappedNativeToken = args[2];

  if (!spokePool || !signer || !wrappedNativeToken) {
    console.log(
      "Usage: yarn tron-deploy-counterfactual-deposit-spokepool <spokePool> <signer> <wrappedNativeToken> [--testnet]"
    );
    process.exit(1);
  }

  validateAddress(spokePool, "spokePool");
  validateAddress(signer, "signer");
  validateAddress(wrappedNativeToken, "wrappedNativeToken");

  const chainId = resolveChainId();

  console.log("=== CounterfactualDepositSpokePool Deployment ===");
  console.log(`Chain ID: ${chainId}`);

  const encodedArgs = encodeArgs(
    ["address", "address", "address"],
    [tronToEvmAddress(spokePool), tronToEvmAddress(signer), tronToEvmAddress(wrappedNativeToken)]
  );

  const artifactPath = path.resolve(
    __dirname,
    "../../../out-tron/CounterfactualDepositSpokePool.sol/CounterfactualDepositSpokePool.json"
  );

  await deployContract({ chainId, artifactPath, encodedArgs });
}

main().catch((err) => {
  console.log("Fatal error:", err.message || err);
  process.exit(1);
});
