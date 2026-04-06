#!/usr/bin/env ts-node
/**
 * Deploys AdminWithdrawManager to Tron.
 *
 * Options:
 *   --testnet  — deploy to Tron Nile testnet (default: mainnet)
 *
 * Usage:
 *   yarn tron-deploy-admin-withdraw-manager <owner> <directWithdrawer> <signer> [--testnet]
 */

import "dotenv/config";
import * as path from "path";
import { deployContract, encodeArgs, tronToEvmAddress, resolveChainId, validateTronAddresses } from "../deploy";

async function main(): Promise<void> {
  const args = process.argv.slice(2).filter((a) => !a.startsWith("-"));
  const owner = args[0];
  const directWithdrawer = args[1];
  const signer = args[2];

  if (!owner || !directWithdrawer || !signer) {
    console.log("Usage: yarn tron-deploy-admin-withdraw-manager <owner> <directWithdrawer> <signer> [--testnet]");
    process.exit(1);
  }

  validateTronAddresses({ owner, directWithdrawer, signer });

  const chainId = resolveChainId();

  console.log("=== AdminWithdrawManager Deployment ===");
  console.log(`Chain ID: ${chainId}`);
  console.log(`Owner: ${owner}`);
  console.log(`Direct withdrawer: ${directWithdrawer}`);
  console.log(`Signer: ${signer}`);

  const encodedArgs = encodeArgs(
    ["address", "address", "address"],
    [tronToEvmAddress(owner), tronToEvmAddress(directWithdrawer), tronToEvmAddress(signer)]
  );

  const artifactPath = path.resolve(__dirname, "../../../out-tron/AdminWithdrawManager.sol/AdminWithdrawManager.json");

  await deployContract({ chainId, artifactPath, encodedArgs });
}

main().catch((err) => {
  console.log("Fatal error:", err.message || err);
  process.exit(1);
});
