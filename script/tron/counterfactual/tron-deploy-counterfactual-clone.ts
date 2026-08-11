#!/usr/bin/env ts-node
/**
 * Deploys a clone from CounterfactualDepositFactoryTron and verifies address prediction.
 *
 * Calls predictAddress (view) to get the expected clone address, then factory.deploy
 * (state-changing) to actually deploy it, and compares the two. The clone's logic comes from the
 * factory's beacon (BeaconProxy), so there is no implementation argument — the address is a function
 * of (salt, initialRoot) only.
 *
 * Options:
 *   --testnet  — deploy to Tron Nile testnet (default: mainnet)
 *
 * Usage:
 *   yarn tron-deploy-counterfactual-clone <factory> <initialRoot> [salt] [--testnet]
 *
 * factory in Tron Base58Check format (T...); initialRoot and salt are 0x-prefixed 32-byte hex.
 * salt defaults to bytes32(0) — the canonical single address per initialRoot.
 */

import "dotenv/config";
import { TronWeb } from "tronweb";
import {
  initTronWeb,
  waitForTx,
  resolveChainId,
  validateTronAddress,
  TRON_MAINNET_CHAIN_ID,
  TRON_TESTNET_CHAIN_ID,
} from "../deploy";

const TRONSCAN_URLS: Record<string, string> = {
  [TRON_MAINNET_CHAIN_ID]: "https://tronscan.org",
  [TRON_TESTNET_CHAIN_ID]: "https://nile.tronscan.org",
};

const BYTES32_RE = /^0x[0-9a-fA-F]{64}$/;
const ZERO_SALT = "0x" + "0".repeat(64);

async function main(): Promise<void> {
  const args = process.argv.slice(2).filter((a) => !a.startsWith("-"));
  const factoryAddress = args[0];
  const initialRoot = args[1];
  const salt = args[2] ?? ZERO_SALT;

  if (!factoryAddress || !initialRoot) {
    console.log("Usage: yarn tron-deploy-counterfactual-clone <factory> <initialRoot> [salt] [--testnet]");
    process.exit(1);
  }
  validateTronAddress(factoryAddress, "factory");
  for (const [name, value] of Object.entries({ initialRoot, salt })) {
    if (!BYTES32_RE.test(value)) {
      console.log(`Error: invalid ${name} "${value}". Expected 0x-prefixed 32-byte hex.`);
      process.exit(1);
    }
  }

  const chainId = resolveChainId();
  const { tronWeb } = initTronWeb(chainId);
  const feeLimit = parseInt(process.env.TRON_FEE_LIMIT || "100000000", 10);

  const factoryTronHex = TronWeb.address.toHex(factoryAddress);
  const tronscanBase = TRONSCAN_URLS[chainId] || "https://tronscan.org";

  const fnParams = [
    { type: "bytes32", value: salt },
    { type: "bytes32", value: initialRoot },
  ];

  // Step 1: predictAddress (view call) — the Tron factory variant predicts with the 0x41 prefix.
  console.log("Calling predictAddress...");
  const predictResult = await tronWeb.transactionBuilder.triggerConstantContract(
    factoryTronHex,
    "predictAddress(bytes32,bytes32)",
    {},
    fnParams
  );
  if (!predictResult.constant_result?.[0]) {
    console.log("Error: predictAddress failed:", JSON.stringify(predictResult, null, 2));
    process.exit(1);
  }
  const predictedEvm = "0x" + predictResult.constant_result[0].slice(24);
  console.log(`Predicted address: ${predictedEvm}`);

  // Step 2: factory.deploy (state-changing)
  console.log(`\nCalling factory.deploy...`);
  console.log(`  Factory:      ${factoryAddress}`);
  console.log(`  Initial root: ${initialRoot}`);
  console.log(`  Salt:         ${salt}`);
  console.log(`  Fee limit:    ${feeLimit} sun (${feeLimit / 1e6} TRX)`);

  const deployTx = await tronWeb.transactionBuilder.triggerSmartContract(
    factoryTronHex,
    "deploy(bytes32,bytes32)",
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

  const txInfo = await waitForTx(tronWeb, txID);

  // Step 3: extract the deployed address from the CounterfactualDeployed event (indexed topic 1).
  const log = txInfo.log?.find((l: any) => l.topics?.length >= 2);
  if (!log) {
    console.log("Error: no CounterfactualDeployed event in transaction.");
    process.exit(1);
  }
  const deployedEvm = "0x" + log.topics[1].slice(24);
  const deployedBase58 = tronWeb.address.fromHex("41" + log.topics[1].slice(24));
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
