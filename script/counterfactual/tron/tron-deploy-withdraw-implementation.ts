#!/usr/bin/env ts-node
/**
 * Deploys WithdrawImplementation to Tron. No constructor args.
 *
 * Usage:
 *   yarn tron-deploy-withdraw-implementation <chain-id>
 */

import "dotenv/config";
import * as path from "path";
import { deployContract } from "./deploy";

async function main(): Promise<void> {
  const chainId = process.argv[2];

  if (!chainId) {
    console.log("Usage: yarn tron-deploy-withdraw-implementation <chain-id>");
    process.exit(1);
  }

  const artifactPath = path.resolve(
    __dirname,
    "../../../out-tron/WithdrawImplementation.sol/WithdrawImplementation.json"
  );

  await deployContract({ chainId, artifactPath });
}

main().catch((err) => {
  console.log("Fatal error:", err.message || err);
  process.exit(1);
});
