#!/usr/bin/env ts-node
/**
 * Deploys CounterfactualDepositSpokePoolTr to Tron.
 *
 * Options:
 *   --testnet  — deploy to Tron Nile testnet (default: mainnet)
 *
 * Usage:
 *   yarn tron-deploy-counterfactual-deposit-spokepool-tron <spokePool> <signer> <wrappedNativeToken> [--testnet]
 */

import "dotenv/config";
import * as path from "path";
import { deployContract, encodeArgs, tronToEvmAddress, resolveChainId, validateTronAddresses } from "../deploy";

async function main(): Promise<void> {
  const args = process.argv.slice(2).filter((a) => !a.startsWith("-"));
  const spokePool = args[0];
  const signer = args[1];
  const wrappedNativeToken = args[2];

  if (!spokePool || !signer || !wrappedNativeToken) {
    console.log(
      "Usage: yarn tron-deploy-counterfactual-deposit-spokepool-tron <spokePool> <signer> <wrappedNativeToken> [--testnet]"
    );
    process.exit(1);
  }

  validateTronAddresses({ spokePool, signer, wrappedNativeToken });

  const chainId = resolveChainId();

  console.log("=== CounterfactualDepositSpokePoolTr Deployment ===");
  console.log(`Chain ID: ${chainId}`);

  const encodedArgs = encodeArgs(
    ["address", "address", "address"],
    [tronToEvmAddress(spokePool), tronToEvmAddress(signer), tronToEvmAddress(wrappedNativeToken)]
  );

  const artifactPath = path.resolve(
    __dirname,
    "../../../out-tron/CounterfactualDepositSpokePoolTr.sol/CounterfactualDepositSpokePoolTr.json"
  );

  await deployContract({ chainId, artifactPath, encodedArgs });
}

main().catch((err) => {
  console.log("Fatal error:", err.message || err);
  process.exit(1);
});
