#!/usr/bin/env ts-node
/**
 * Deploys CounterfactualDeposit (the dispatcher every counterfactual clone delegatecalls) to Tron,
 * bound to the beacon proxy via its immutable BEACON.
 *
 * Normally deployed by tron-deploy-counterfactual-beacon as part of the beacon stack; use this
 * standalone script only to redeploy the dispatcher against an existing beacon (then have the beacon
 * owner call setImplementation with the new address).
 *
 * Options:
 *   --testnet  — deploy to Tron Nile testnet (default: mainnet)
 *
 * Usage:
 *   yarn tron-deploy-counterfactual-deposit <beacon> [--testnet]
 *     beacon — CounterfactualBeacon proxy address (Tron Base58Check, T...)
 */

import "dotenv/config";
import * as path from "path";
import { deployContract, encodeArgs, tronToEvmAddress, validateTronAddress, resolveChainId } from "../deploy";

async function main(): Promise<void> {
  const args = process.argv.slice(2).filter((a) => !a.startsWith("-"));
  const beacon = args[0];

  if (!beacon) {
    console.log("Usage: yarn tron-deploy-counterfactual-deposit <beacon> [--testnet]");
    process.exit(1);
  }
  validateTronAddress(beacon, "beacon");

  const chainId = resolveChainId();

  console.log("=== CounterfactualDeposit Deployment ===");
  console.log(`Chain ID: ${chainId}`);
  console.log(`Beacon:   ${beacon}`);

  const encodedArgs = encodeArgs(["address"], [tronToEvmAddress(beacon)]);
  const artifactPath = path.resolve(
    __dirname,
    "../../../out-tron/CounterfactualDeposit.sol/CounterfactualDeposit.json"
  );

  await deployContract({ chainId, artifactPath, encodedArgs });
  console.log("Next: the beacon owner must call setImplementation(<new dispatcher>) to activate it.");
}

main().catch((err) => {
  console.log("Fatal error:", err.message || err);
  process.exit(1);
});
