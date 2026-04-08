#!/usr/bin/env ts-node
/**
 * Deploys CounterfactualDeposit to Tron. No constructor args.
 *
 * This is the implementation contract that the factory deploys clones of.
 *
 * Options:
 *   --testnet  — deploy to Tron Nile testnet (default: mainnet)
 *
 * Usage:
 *   yarn tron-deploy-counterfactual-deposit [--testnet]
 */

import "dotenv/config";
import * as path from "path";
import { deployContract, resolveChainId } from "../deploy";

async function main(): Promise<void> {
  const chainId = resolveChainId();

  console.log("=== CounterfactualDeposit Deployment ===");
  console.log(`Chain ID: ${chainId}`);

  const artifactPath = path.resolve(
    __dirname,
    "../../../out-tron/CounterfactualDeposit.sol/CounterfactualDeposit.json"
  );

  await deployContract({ chainId, artifactPath });
}

main().catch((err) => {
  console.log("Fatal error:", err.message || err);
  process.exit(1);
});
