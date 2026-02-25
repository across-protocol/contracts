#!/usr/bin/env ts-node
/**
 * Shared TronWeb deployer for Foundry FFI.
 *
 * Usage:
 *   npx ts-node deploy.ts <chain-id> <artifact-json-path> [abi-encoded-constructor-args-hex]
 *
 * Env vars:
 *   MNEMONIC              — BIP-39 mnemonic (derives account 0 private key)
 *   NODE_URL_728126428  — Tron mainnet full node URL
 *   NODE_URL_3448148188 — Tron Nile testnet full node URL
 *   TRON_FEE_LIMIT      — optional, in sun (default: 1500000000 = 1500 TRX)
 *
 * Stdout: ABI-encoded address (0x-prefixed, 32-byte padded) for Foundry abi.decode
 * Stderr: human-readable logs
 */

import * as fs from "fs";
import * as path from "path";
import { Wallet } from "ethers";
import { TronWeb } from "tronweb";

const POLL_INTERVAL_MS = 3000;
const MAX_POLL_ATTEMPTS = 40; // ~2 minutes

async function main(): Promise<void> {
  const chainId = process.argv[2];
  const artifactPath = process.argv[3];
  const encodedArgs = process.argv[4]; // optional

  if (!chainId || !artifactPath) {
    console.error("Usage: npx ts-node deploy.ts <chain-id> <artifact-json-path> [abi-encoded-constructor-args-hex]");
    process.exit(1);
  }

  const mnemonic = process.env.MNEMONIC;
  const fullNode = process.env[`NODE_URL_${chainId}`];
  if (!mnemonic) {
    console.error("Error: MNEMONIC env var is required.");
    process.exit(1);
  }
  if (!fullNode) {
    console.error(`Error: NODE_URL_${chainId} env var is required.`);
    process.exit(1);
  }

  // Derive account 0 private key from mnemonic (same derivation as Foundry's vm.deriveKey(mnemonic, 0))
  const privateKey = Wallet.fromMnemonic(mnemonic).privateKey.slice(2); // strip 0x for TronWeb

  const feeLimit = parseInt(process.env.TRON_FEE_LIMIT || "1500000000", 10);

  // Read artifact
  const artifact = JSON.parse(fs.readFileSync(artifactPath, "utf-8"));
  const abi = artifact.abi;
  let bytecode: string = artifact.bytecode?.object || artifact.bytecode;
  if (typeof bytecode === "string" && bytecode.startsWith("0x")) {
    bytecode = bytecode.slice(2);
  }
  if (!abi || !bytecode) {
    console.error("Error: artifact missing abi or bytecode.");
    process.exit(1);
  }

  const contractName = path.basename(artifactPath, ".json");

  // Strip 0x from encoded args if provided
  let parameter: string | undefined;
  if (encodedArgs) {
    parameter = encodedArgs.startsWith("0x") ? encodedArgs.slice(2) : encodedArgs;
  }

  const tronWeb = new TronWeb({ fullHost: fullNode, privateKey });

  console.error(`Deploying ${contractName} to ${fullNode}...`);
  if (parameter) console.error(`Constructor args: 0x${parameter}`);
  console.error(`Fee limit: ${feeLimit} sun (${feeLimit / 1e6} TRX)`);

  // Build the create contract transaction
  const txOptions = {
    abi,
    bytecode,
    name: contractName,
    feeLimit,
    ...(parameter ? { parameters: [] as unknown[], rawParameter: parameter } : {}),
  };

  const tx = await tronWeb.transactionBuilder.createSmartContract(txOptions);
  const signedTx = await tronWeb.trx.sign(tx);
  const result = await tronWeb.trx.sendRawTransaction(signedTx);

  if (!(result as any).result) {
    console.error("Error: transaction rejected:", JSON.stringify(result, null, 2));
    process.exit(1);
  }

  const txID: string = (result as any).txid || (result as any).transaction?.txID;
  console.error(`Transaction sent: ${txID}`);

  // Poll for confirmation
  let txInfo: any;
  for (let i = 0; i < MAX_POLL_ATTEMPTS; i++) {
    await new Promise((r) => setTimeout(r, POLL_INTERVAL_MS));
    txInfo = await tronWeb.trx.getTransactionInfo(txID);
    if (txInfo && txInfo.id) {
      break;
    }
    console.error(`Waiting for confirmation... (${i + 1}/${MAX_POLL_ATTEMPTS})`);
  }

  if (!txInfo || !txInfo.id) {
    console.error("Error: transaction not confirmed within timeout.");
    process.exit(1);
  }

  if (txInfo.receipt?.result !== "SUCCESS") {
    console.error("Error: transaction failed:", JSON.stringify(txInfo, null, 2));
    process.exit(1);
  }

  // Extract contract address (Tron hex format: 41 + 20 bytes)
  const tronHexAddress: string = txInfo.contract_address;
  if (!tronHexAddress) {
    console.error("Error: no contract_address in transaction info.");
    process.exit(1);
  }

  // Convert Tron hex address (41...) to EVM 20-byte hex
  let evmAddress = tronHexAddress;
  if (evmAddress.startsWith("41") && evmAddress.length === 42) {
    evmAddress = evmAddress.slice(2);
  }

  const base58Address = tronWeb.address.fromHex(tronHexAddress);

  console.error(`Contract deployed!`);
  console.error(`  Tron address: ${base58Address}`);
  console.error(`  Hex address:  0x${evmAddress}`);
  console.error(`  TX ID:        ${txID}`);

  // Write deployment artifact
  const deploymentsDir = path.resolve(__dirname, "../../../deployments/tron");
  fs.mkdirSync(deploymentsDir, { recursive: true });
  const artifactFile = path.join(deploymentsDir, `${contractName}.json`);

  const deployment = {
    contractName,
    address: `0x${evmAddress}`,
    tronAddress: base58Address,
    transactionHash: txID,
    constructorArgs: encodedArgs || null,
    abi,
    deployedAt: new Date().toISOString(),
    network: fullNode,
    solcVersion: "0.8.25",
  };

  fs.writeFileSync(artifactFile, JSON.stringify(deployment, null, 2) + "\n");
  console.error(`  Artifact:     ${artifactFile}`);

  // ABI-encode the address for Foundry: left-pad to 32 bytes
  const padded = evmAddress.toLowerCase().padStart(64, "0");
  process.stdout.write(`0x${padded}`);
}

main().catch((err) => {
  console.error("Fatal error:", err.message || err);
  process.exit(1);
});
