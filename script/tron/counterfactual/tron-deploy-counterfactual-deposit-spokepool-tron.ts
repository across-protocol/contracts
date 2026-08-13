#!/usr/bin/env ts-node
/**
 * Deploys CounterfactualDepositSpokePoolTr (the SpokePool route leaf) to Tron. No constructor args —
 * the leaf resolves SpokePool, signer, tokens, and fee caps at runtime from the clone's beacon
 * (the CounterfactualBeacon proxy), so the beacon stack must be deployed and configured first.
 *
 * Options:
 *   --testnet  — deploy to Tron Nile testnet (default: mainnet)
 *
 * Usage:
 *   yarn tron-deploy-counterfactual-deposit-spokepool-tron [--testnet]
 */

import "dotenv/config";
import * as path from "path";
import { deployContract, resolveChainId } from "../deploy";

async function main(): Promise<void> {
  const chainId = resolveChainId();

  console.log("=== CounterfactualDepositSpokePoolTr Deployment ===");
  console.log(`Chain ID: ${chainId}`);

  const artifactPath = path.resolve(
    __dirname,
    "../../../out-tron/CounterfactualDepositSpokePoolTr.sol/CounterfactualDepositSpokePoolTr.json"
  );

  await deployContract({ chainId, artifactPath });
}

main().catch((err) => {
  console.log("Fatal error:", err.message || err);
  process.exit(1);
});
