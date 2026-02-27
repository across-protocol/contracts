#!/usr/bin/env ts-node
/**
 * Deploys a clone from CounterfactualDepositFactoryTron and verifies address prediction.
 *
 * Calls predictDepositAddress (view) to get the expected clone address, then calls
 * factory.deploy (state-changing) to actually deploy it, and compares the two.
 *
 * Usage:
 *   npx ts-node deploy-clone.ts <chain-id> <factory-address> <implementation-address> <params-hash> <salt>
 *
 * All addresses in 0x hex format. paramsHash and salt are 0x-prefixed 32-byte hex values.
 *
 * Env vars:
 *   MNEMONIC              — BIP-39 mnemonic (derives account 0 private key)
 *   NODE_URL_728126428    — Tron mainnet full node URL
 *   NODE_URL_3448148188   — Tron Nile testnet full node URL
 *   TRON_FEE_LIMIT        — optional, in sun (default: 1500000000 = 1500 TRX)
 *
 */

import "dotenv/config";
import { Wallet } from "ethers";
import { TronWeb } from "tronweb";

const POLL_INTERVAL_MS = 3000;
const MAX_POLL_ATTEMPTS = 40; // ~2 minutes

const TRONSCAN_URLS: Record<string, string> = {
  "728126428": "https://tronscan.org",
  "3448148188": "https://nile.tronscan.org",
};

// Matches a 0x-prefixed 20-byte hex address (40 hex chars after 0x).
const ADDRESS_RE = /^0x[0-9a-fA-F]{40}$/;

// Matches a 0x-prefixed 32-byte hex value (64 hex chars after 0x).
const BYTES32_RE = /^0x[0-9a-fA-F]{64}$/;

function validateArgs(factoryAddress: string, implementationAddress: string, paramsHash: string, salt: string): void {
  if (!ADDRESS_RE.test(factoryAddress)) {
    console.log(`Error: invalid factory address "${factoryAddress}". Expected 0x-prefixed 20-byte hex.`);
    process.exit(1);
  }
  if (!ADDRESS_RE.test(implementationAddress)) {
    console.log(`Error: invalid implementation address "${implementationAddress}". Expected 0x-prefixed 20-byte hex.`);
    process.exit(1);
  }
  if (!BYTES32_RE.test(paramsHash)) {
    console.log(`Error: invalid paramsHash "${paramsHash}". Expected 0x-prefixed 32-byte hex.`);
    process.exit(1);
  }
  if (!BYTES32_RE.test(salt)) {
    console.log(`Error: invalid salt "${salt}". Expected 0x-prefixed 32-byte hex.`);
    process.exit(1);
  }
}

async function main(): Promise<void> {
  const chainId = process.argv[2];
  const factoryAddress = process.argv[3];
  const implementationAddress = process.argv[4];
  const paramsHash = process.argv[5];
  const salt = process.argv[6];

  if (!chainId || !factoryAddress || !implementationAddress || !paramsHash || !salt) {
    console.log(
      "Usage: npx ts-node deploy-clone.ts <chain-id> <factory-address> <implementation-address> <params-hash> <salt>"
    );
    process.exit(1);
  }

  // Validate that addresses are 0x-prefixed 20-byte hex and bytes32 values are 0x-prefixed 32-byte hex.
  validateArgs(factoryAddress, implementationAddress, paramsHash, salt);

  const mnemonic = process.env.MNEMONIC;
  const fullNode = process.env[`NODE_URL_${chainId}`];
  if (!mnemonic) {
    console.log("Error: MNEMONIC env var is required.");
    process.exit(1);
  }
  if (!fullNode) {
    console.log(`Error: NODE_URL_${chainId} env var is required.`);
    process.exit(1);
  }

  // Derive account 0 private key from mnemonic (same derivation as Foundry's vm.deriveKey(mnemonic, 0)).
  // TronWeb expects a raw hex key without the 0x prefix.
  const wallet = Wallet.fromMnemonic(mnemonic);
  const privateKey = wallet.privateKey.slice(2);
  const feeLimit = parseInt(process.env.TRON_FEE_LIMIT || "1500000000", 10);

  const tronWeb = new TronWeb({ fullHost: fullNode, privateKey });

  // Tron uses 41-prefixed hex addresses internally (instead of 0x).
  const factoryTronHex = "41" + factoryAddress.slice(2).toLowerCase();
  const tronscanBase = TRONSCAN_URLS[chainId] || "https://tronscan.org";

  // These are the parameters for both predictDepositAddress and deploy — same signature.
  const fnParams = [
    { type: "address", value: implementationAddress },
    { type: "bytes32", value: paramsHash },
    { type: "bytes32", value: salt },
  ];

  // --- Step 1: Call predictDepositAddress (view call) ---
  // Uses triggerConstantContract which executes locally without a transaction.
  console.log("Calling predictDepositAddress...");
  const predictResult = await tronWeb.transactionBuilder.triggerConstantContract(
    factoryTronHex,
    "predictDepositAddress(address,bytes32,bytes32)",
    {},
    fnParams
  );

  if (!predictResult.constant_result?.[0]) {
    console.log("Error: predictDepositAddress failed:", JSON.stringify(predictResult, null, 2));
    process.exit(1);
  }

  // The return value is a 32-byte ABI-encoded address (left-padded with zeros).
  // Slice off the first 24 hex chars (12 bytes of zero-padding) to get the 20-byte address.
  const predictedEvm = "0x" + predictResult.constant_result[0].slice(24);
  console.log(`Predicted address: ${predictedEvm}`);

  // --- Step 2: Call factory.deploy (state-changing transaction) ---
  // Uses triggerSmartContract which builds a transaction that must be signed and broadcast.
  console.log(`\nCalling factory.deploy on ${fullNode}...`);
  console.log(`  Factory:        ${factoryAddress}`);
  console.log(`  Implementation: ${implementationAddress}`);
  console.log(`  Params hash:    ${paramsHash}`);
  console.log(`  Salt:           ${salt}`);
  console.log(`  Fee limit:      ${feeLimit} sun (${feeLimit / 1e6} TRX)`);

  const deployTx = await tronWeb.transactionBuilder.triggerSmartContract(
    factoryTronHex,
    "deploy(address,bytes32,bytes32)",
    { feeLimit },
    fnParams
  );

  if (!deployTx.result?.result) {
    console.log("Error: triggerSmartContract failed:", JSON.stringify(deployTx, null, 2));
    process.exit(1);
  }

  // Sign the transaction with the deployer's private key (SHA-256 + secp256k1, not keccak256).
  const signedTx = await tronWeb.trx.sign(deployTx.transaction);

  // Broadcast the signed transaction to the Tron network.
  const broadcastResult = await tronWeb.trx.sendRawTransaction(signedTx);

  if (!(broadcastResult as any).result) {
    console.log("Error: transaction rejected:", JSON.stringify(broadcastResult, null, 2));
    process.exit(1);
  }

  const txID: string = (broadcastResult as any).txid || (broadcastResult as any).transaction?.txID;
  console.log(`Transaction sent: ${txID}`);

  // --- Step 3: Poll for confirmation ---
  // Tron doesn't return receipts synchronously. Poll getTransactionInfo until the tx is confirmed.
  let txInfo: any;
  for (let i = 0; i < MAX_POLL_ATTEMPTS; i++) {
    await new Promise((r) => setTimeout(r, POLL_INTERVAL_MS));
    txInfo = await tronWeb.trx.getTransactionInfo(txID);
    if (txInfo && txInfo.id) break;
    console.log(`Waiting for confirmation... (${i + 1}/${MAX_POLL_ATTEMPTS})`);
  }

  if (!txInfo?.id) {
    console.log("Error: transaction not confirmed within timeout.");
    process.exit(1);
  }

  if (txInfo.receipt?.result !== "SUCCESS") {
    console.log("Error: transaction failed:", JSON.stringify(txInfo, null, 2));
    process.exit(1);
  }

  // --- Step 4: Extract deployed address from the DepositAddressCreated event ---
  // Event signature: DepositAddressCreated(address indexed depositAddress, address indexed implementation, bytes32 indexed paramsHash, bytes32 salt)
  // topics[0] = event signature hash, topics[1] = depositAddress (32-byte padded, no 0x prefix in TronWeb)
  const log = txInfo.log?.[0];
  if (!log?.topics?.[1]) {
    console.log("Error: no DepositAddressCreated event in transaction.");
    process.exit(1);
  }

  // Extract the 20-byte address from the 32-byte padded topic.
  const deployedEvm = "0x" + log.topics[1].slice(24);
  const deployedTronHex = "41" + log.topics[1].slice(24);
  const deployedBase58 = tronWeb.address.fromHex(deployedTronHex);
  const match = predictedEvm.toLowerCase() === deployedEvm.toLowerCase();

  console.log(`\nClone deployed!`);
  console.log(`  Predicted:  ${predictedEvm}`);
  console.log(`  Deployed:   ${deployedEvm}`);
  console.log(`  Tron addr:  ${deployedBase58}`);
  console.log(`  Match:      ${match}`);
  console.log(`  TX ID:      ${txID}`);
  console.log(`  Tronscan:   ${tronscanBase}/#/contract/${deployedBase58}`);

  if (!match) {
    console.log("\nERROR: Address prediction mismatch!");
    process.exit(1);
  }
}

main().catch((err) => {
  console.log("Fatal error:", err.message || err);
  process.exit(1);
});
