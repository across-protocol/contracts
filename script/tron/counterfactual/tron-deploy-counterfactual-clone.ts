#!/usr/bin/env ts-node
/**
 * Deploys a clone from CounterfactualDepositFactoryTron and verifies address prediction.
 *
 * Calls predictDepositAddress (view) to get the expected clone address, then calls
 * factory.deploy (state-changing) to actually deploy it, and compares the two.
 *
 * Options:
 *   --testnet  — deploy to Tron Nile testnet (default: mainnet)
 *
 * Usage:
 *   yarn tron-deploy-counterfactual-clone <factory> <implementation> <merkleRoot> <salt> [--testnet]
 *
 * Addresses in Tron Base58Check format (T...). merkleRoot and salt are 0x-prefixed 32-byte hex values.
 */

import "dotenv/config";
import { TronWeb } from "tronweb";
import {
  tronToEvmAddress,
  resolveChainId,
  TRON_MAINNET_CHAIN_ID,
  TRON_TESTNET_CHAIN_ID,
  validateTronAddresses,
} from "../deploy";

const POLL_INTERVAL_MS = 3000;
const MAX_POLL_ATTEMPTS = 40; // ~2 minutes

const TRONSCAN_URLS: Record<string, string> = {
  [TRON_MAINNET_CHAIN_ID]: "https://tronscan.org",
  [TRON_TESTNET_CHAIN_ID]: "https://nile.tronscan.org",
};

const BYTES32_RE = /^0x[0-9a-fA-F]{64}$/;

function validateArgs(factoryAddress: string, implementationAddress: string, merkleRoot: string, salt: string): void {
  validateTronAddresses({ factory: factoryAddress, implementation: implementationAddress });
  if (!BYTES32_RE.test(merkleRoot)) {
    console.log(`Error: invalid merkleRoot "${merkleRoot}". Expected 0x-prefixed 32-byte hex.`);
    process.exit(1);
  }
  if (!BYTES32_RE.test(salt)) {
    console.log(`Error: invalid salt "${salt}". Expected 0x-prefixed 32-byte hex.`);
    process.exit(1);
  }
}

async function main(): Promise<void> {
  const args = process.argv.slice(2).filter((a) => !a.startsWith("-"));
  const factoryAddress = args[0];
  const implementationAddress = args[1];
  const merkleRoot = args[2];
  const salt = args[3];

  if (!factoryAddress || !implementationAddress || !merkleRoot || !salt) {
    console.log(
      "Usage: yarn tron-deploy-counterfactual-clone <factory> <implementation> <merkleRoot> <salt> [--testnet]"
    );
    process.exit(1);
  }

  const chainId = resolveChainId();

  validateArgs(factoryAddress, implementationAddress, merkleRoot, salt);

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

  const feeLimit = parseInt(process.env.TRON_FEE_LIMIT || "100000000", 10);

  const tronWeb = new TronWeb({ fullHost: fullNode });

  const { ethersHDNodeWallet, Mnemonic } = tronWeb.utils.ethersUtils;
  const mnemonicObj = Mnemonic.fromPhrase(mnemonic);
  const wallet = ethersHDNodeWallet.fromMnemonic(mnemonicObj, "m/44'/60'/0'/0/0");
  const privateKey = wallet.privateKey.slice(2);
  tronWeb.setPrivateKey(privateKey);

  const factoryTronHex = TronWeb.address.toHex(factoryAddress);
  const implementationEvmAddress = tronToEvmAddress(implementationAddress);
  const tronscanBase = TRONSCAN_URLS[chainId] || "https://tronscan.org";

  const fnParams = [
    { type: "address", value: implementationEvmAddress },
    { type: "bytes32", value: merkleRoot },
    { type: "bytes32", value: salt },
  ];

  // Step 1: Call predictDepositAddress (view call)
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

  const predictedEvm = "0x" + predictResult.constant_result[0].slice(24);
  console.log(`Predicted address: ${predictedEvm}`);

  // Step 2: Call factory.deploy (state-changing transaction)
  console.log(`\nCalling factory.deploy on ${fullNode}...`);
  console.log(`  Factory:        ${factoryAddress}`);
  console.log(`  Implementation: ${implementationAddress}`);
  console.log(`  Merkle root:    ${merkleRoot}`);
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

  const signedTx = await tronWeb.trx.sign(deployTx.transaction);
  const broadcastResult = await tronWeb.trx.sendRawTransaction(signedTx);

  if (!(broadcastResult as any).result) {
    console.log("Error: transaction rejected:", JSON.stringify(broadcastResult, null, 2));
    process.exit(1);
  }

  const txID: string = (broadcastResult as any).txid || (broadcastResult as any).transaction?.txID;
  console.log(`Transaction sent: ${txID}`);

  // Step 3: Poll for confirmation
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

  // Step 4: Extract deployed address from the DepositAddressCreated event
  const log = txInfo.log?.[0];
  if (!log?.topics?.[1]) {
    console.log("Error: no DepositAddressCreated event in transaction.");
    process.exit(1);
  }

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
