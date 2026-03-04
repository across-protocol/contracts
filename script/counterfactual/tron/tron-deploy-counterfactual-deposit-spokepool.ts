#!/usr/bin/env ts-node
/**
 * Deploys CounterfactualDepositSpokePool to Tron.
 *
 * Constructor args:
 *   spokePool          — Across SpokePool contract address (Tron Base58Check, T...)
 *   signer             — EIP-712 signer address (Tron Base58Check, T...)
 *   wrappedNativeToken — WETH address on this chain (Tron Base58Check, T...)
 *
 * Usage:
 *   yarn tron-deploy-counterfactual-deposit-spokepool <chain-id> <spokePool> <signer> <wrappedNativeToken>
 */

import "dotenv/config";
import * as path from "path";
import { TronWeb } from "tronweb";
import { deployContract, encodeArgs, tronToEvmAddress } from "./deploy";

function validateAddress(value: string, name: string): void {
  if (!TronWeb.isAddress(value)) {
    console.log(`Error: invalid ${name} "${value}". Expected Tron Base58Check address (T...).`);
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
  const encodedArgs = encodeArgs(
    ["address", "address", "address"],
    [tronToEvmAddress(spokePool), tronToEvmAddress(signer), tronToEvmAddress(wrappedNativeToken)]
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
