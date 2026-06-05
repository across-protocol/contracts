#!/usr/bin/env ts-node
/**
 * Deploys CounterfactualDepositFactoryTron to Tron. No constructor args.
 *
 * Options:
 *   --testnet  — deploy to Tron Nile testnet (default: mainnet)
 *
 * Usage:
 *   yarn tron-deploy-counterfactual-factory [--testnet]
 */

import "dotenv/config";
import * as path from "path";
import { deployContract, resolveChainId } from "../deploy";

async function main(): Promise<void> {
  const chainId = resolveChainId();

  console.log("=== CounterfactualDepositFactoryTron Deployment ===");
  console.log(`Chain ID: ${chainId}`);

  const artifactPath = path.resolve(
    __dirname,
    "../../../out-tron/CounterfactualDepositFactoryTron.sol/CounterfactualDepositFactoryTron.json"
  );

  await deployContract({ chainId, artifactPath });
}

main().catch((err) => {
  console.log("Fatal error:", err.message || err);
  process.exit(1);
});
