#!/usr/bin/env ts-node
/**
 * Deploys CounterfactualDepositFactoryTron to Tron, bound to the beacon proxy (every clone it deploys
 * is a BeaconProxy anchored to that beacon).
 *
 * Options:
 *   --testnet  — deploy to Tron Nile testnet (default: mainnet)
 *
 * Usage:
 *   yarn tron-deploy-counterfactual-factory <beacon> [--testnet]
 *     beacon — CounterfactualBeacon proxy address (Tron Base58Check, T...)
 */

import "dotenv/config";
import * as path from "path";
import { deployContract, encodeArgs, tronToEvmAddress, validateTronAddress, resolveChainId } from "../deploy";

async function main(): Promise<void> {
  const args = process.argv.slice(2).filter((a) => !a.startsWith("-"));
  const beacon = args[0];

  if (!beacon) {
    console.log("Usage: yarn tron-deploy-counterfactual-factory <beacon> [--testnet]");
    process.exit(1);
  }
  validateTronAddress(beacon, "beacon");

  const chainId = resolveChainId();

  console.log("=== CounterfactualDepositFactoryTron Deployment ===");
  console.log(`Chain ID: ${chainId}`);
  console.log(`Beacon:   ${beacon}`);

  const encodedArgs = encodeArgs(["address"], [tronToEvmAddress(beacon)]);
  const artifactPath = path.resolve(
    __dirname,
    "../../../out-tron/CounterfactualDepositFactoryTron.sol/CounterfactualDepositFactoryTron.json"
  );

  await deployContract({ chainId, artifactPath, encodedArgs });
}

main().catch((err) => {
  console.log("Fatal error:", err.message || err);
  process.exit(1);
});
