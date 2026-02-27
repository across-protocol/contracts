#!/usr/bin/env ts-node
/**
 * Deploys CounterfactualDepositSpokePool to Tron.
 *
 * Constructor args:
 *   spokePool          — Across SpokePool contract address (0x hex)
 *   signer             — EIP-712 signer address (0x hex)
 *   wrappedNativeToken — WETH address on this chain (0x hex)
 *
 * Usage:
 *   yarn tron-deploy-counterfactual-deposit-spokepool <chain-id> <spokePool> <signer> <wrappedNativeToken>
 */

import "dotenv/config";
import * as path from "path";
import { utils } from "ethers";
import { deployContract } from "./deploy";

const ADDRESS_RE = /^0x[0-9a-fA-F]{40}$/;

function validateAddress(value: string, name: string): void {
  if (!ADDRESS_RE.test(value)) {
    console.log(`Error: invalid ${name} "${value}". Expected 0x-prefixed 20-byte hex.`);
    process.exit(1);
  }
}

async function main(): Promise<void> {
  const chainId = process.argv[2];
  const spokePool = process.argv[3];
  const signer = process.argv[4];
  const wrappedNativeToken = process.argv[5];

  if (!chainId || !spokePool || !signer || !wrappedNativeToken) {
    console.log(
      "Usage: yarn tron-deploy-counterfactual-deposit-spokepool <chain-id> <spokePool> <signer> <wrappedNativeToken>"
    );
    process.exit(1);
  }

  // Validate all three addresses.
  validateAddress(spokePool, "spokePool");
  validateAddress(signer, "signer");
  validateAddress(wrappedNativeToken, "wrappedNativeToken");

  // ABI-encode constructor args: (address spokePool, address signer, address wrappedNativeToken).
  const encodedArgs = utils.defaultAbiCoder.encode(
    ["address", "address", "address"],
    [spokePool, signer, wrappedNativeToken]
  );

  const artifactPath = path.resolve(
    __dirname,
    "../../../out-tron/CounterfactualDepositSpokePool.sol/CounterfactualDepositSpokePool.json"
  );

  await deployContract({ chainId, artifactPath, encodedArgs });
}

main().catch((err) => {
  console.log("Fatal error:", err.message || err);
  process.exit(1);
});
