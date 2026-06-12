#!/usr/bin/env ts-node
/**
 * Deploys SpokePoolPeriphery to Tron. The constructor internally deploys a SwapProxy
 * (accessible at `spokePoolPeriphery.swapProxy()`), so a separate SwapProxy deployment
 * is not required when deploying the periphery.
 *
 * Options:
 *   --testnet  — deploy to Tron Nile testnet (default: mainnet)
 *
 * Usage:
 *   yarn tron-deploy-spoke-pool-periphery <permit2> <multicall3> [--testnet]
 */

import "dotenv/config";
import * as path from "path";
import { deployContract, encodeArgs, tronToEvmAddress, resolveChainId, validateTronAddresses } from "../deploy";

async function main(): Promise<void> {
  const args = process.argv.slice(2).filter((a) => !a.startsWith("-"));
  const permit2 = args[0];
  const multicall3 = args[1];

  if (!permit2 || !multicall3) {
    console.log("Usage: yarn tron-deploy-spoke-pool-periphery <permit2> <multicall3> [--testnet]");
    process.exit(1);
  }

  validateTronAddresses({ permit2, multicall3 });

  const chainId = resolveChainId();

  console.log("=== SpokePoolPeriphery Deployment ===");
  console.log(`Chain ID: ${chainId}`);
  console.log(`Permit2: ${permit2}`);
  console.log(`Multicall3: ${multicall3}`);

  const encodedArgs = encodeArgs(
    ["address", "address"],
    [tronToEvmAddress(permit2), tronToEvmAddress(multicall3)]
  );

  const artifactPath = path.resolve(__dirname, "../../../out-tron/SpokePoolPeriphery.sol/SpokePoolPeriphery.json");

  await deployContract({ chainId, artifactPath, encodedArgs });
}

main().catch((err) => {
  console.log("Fatal error:", err.message || err);
  process.exit(1);
});
