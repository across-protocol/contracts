#!/usr/bin/env ts-node
/**
 * General-purpose Tron deployment entry point. Deploys any contract listed in the
 * REGISTRY below, taking the contract name (and any constructor args) as runtime
 * arguments. Contracts with bespoke deployment logic (SP1Helios genesis, the
 * universal SpokePool proxy flow, counterfactual clones) keep their dedicated
 * scripts — this entry point only covers contracts whose deployment is "compile,
 * encode constructor args, deploy".
 *
 * Address arguments use Tron Base58Check format (T...) and are converted to EVM
 * hex before encoding.
 *
 * Options:
 *   --testnet  — deploy to Tron Nile testnet (default: mainnet)
 *
 * Usage:
 *   yarn tron-deploy <Contract> [--testnet] [constructorArgs...]
 *
 * Examples:
 *   yarn tron-deploy AcrossEventEmitter
 *   yarn tron-deploy AcrossEventEmitter --testnet
 */

import "dotenv/config";
import * as path from "path";
import { deployContract, encodeArgs, tronToEvmAddress, resolveChainId, validateTronAddress } from "./deploy";

interface ArgSpec {
  name: string;
  type: string; // Solidity ABI type, e.g. "address", "uint256"
}

interface ContractSpec {
  /** Artifact path relative to out-tron/ (the artifact filename's basename is used as the contract name). */
  artifact: string;
  /** Constructor args in order. Omit for contracts with no constructor args. */
  args?: ArgSpec[];
}

// Contracts deployable via this generic entry point. Add an entry here instead of
// creating a new per-contract script + yarn target.
const REGISTRY: Record<string, ContractSpec> = {
  AcrossEventEmitter: { artifact: "AcrossEventEmitter.sol/AcrossEventEmitter.json" },
};

function usage(): never {
  const names = Object.keys(REGISTRY).sort().join(", ");
  console.log("Usage: yarn tron-deploy <Contract> [--testnet] [constructorArgs...]");
  console.log(`Available contracts: ${names}`);
  process.exit(1);
}

async function main(): Promise<void> {
  const positional = process.argv.slice(2).filter((a) => !a.startsWith("-"));
  const contractName = positional[0];
  const argValues = positional.slice(1);

  if (!contractName) usage();

  const spec = REGISTRY[contractName];
  if (!spec) {
    console.log(`Error: unknown contract "${contractName}".`);
    usage();
  }

  const argSpecs = spec.args ?? [];
  if (argValues.length !== argSpecs.length) {
    const sig = argSpecs.map((a) => `<${a.name}>`).join(" ");
    console.log(`Error: ${contractName} expects ${argSpecs.length} arg(s): ${sig || "(none)"}.`);
    process.exit(1);
  }

  const chainId = resolveChainId();

  console.log(`=== ${contractName} Deployment ===`);
  console.log(`Chain ID: ${chainId}`);

  // Convert and validate args: Tron addresses (T...) become EVM hex; other types pass through as-is.
  const encodedValues = argSpecs.map((argSpec, i) => {
    const raw = argValues[i];
    console.log(`${argSpec.name}: ${raw}`);
    if (argSpec.type === "address") {
      validateTronAddress(raw, argSpec.name);
      return tronToEvmAddress(raw);
    }
    return raw;
  });

  const encodedArgs = argSpecs.length
    ? encodeArgs(
        argSpecs.map((a) => a.type),
        encodedValues
      )
    : undefined;

  const artifactPath = path.resolve(__dirname, "../../out-tron", spec.artifact);

  await deployContract({ chainId, artifactPath, encodedArgs });
}

main().catch((err) => {
  console.log("Fatal error:", err.message || err);
  process.exit(1);
});
