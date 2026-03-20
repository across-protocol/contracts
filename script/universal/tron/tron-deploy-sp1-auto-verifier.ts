#!/usr/bin/env ts-node
/**
 * Deploys SP1AutoVerifier to Tron via TronWeb.
 *
 * SP1AutoVerifier has no constructor args — it's a no-op verifier for testing.
 *
 * Env vars:
 *   MNEMONIC              — BIP-39 mnemonic (derives account 0 private key)
 *   NODE_URL_728126428    — Tron mainnet full node URL
 *   NODE_URL_3448148188   — Tron Nile testnet full node URL
 *   TRON_FEE_LIMIT        — optional, in sun (default: 1500000000 = 1500 TRX)
 *
 * Usage:
 *   yarn tron-deploy-sp1-auto-verifier <chain-id>
 */

import * as path from "path";
import { deployContract } from "./deploy";

async function main(): Promise<void> {
  const chainId = process.argv[2];
  if (!chainId) {
    console.log("Usage: yarn tron-deploy-sp1-auto-verifier <chain-id>");
    process.exit(1);
  }

  console.log("=== SP1AutoVerifier Tron Deployment ===");
  console.log(`Chain ID: ${chainId}`);

  const artifactPath = path.resolve(__dirname, "../../../out-tron-universal/SP1AutoVerifier.sol/SP1AutoVerifier.json");

  await deployContract({ chainId, artifactPath });
}

main().catch((err) => {
  console.log("Fatal error:", err.message || err);
  process.exit(1);
});
