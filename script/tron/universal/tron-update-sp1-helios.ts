#!/usr/bin/env ts-node
/**
 * Updates SP1Helios on Tron to extend the 7-day MAX_SLOT_AGE window.
 *
 * Reads current on-chain state (head, header, sync committee hash), fetches the
 * sync committee hash for the target period from an Ethereum consensus RPC, then
 * calls SP1Helios.update() with a valid ProofOutputs payload. Requires the
 * SP1AutoVerifier (no-op verifier) to be attached — real ZK proofs are not needed.
 *
 * Env vars:
 *   MNEMONIC                     — BIP-39 mnemonic (derives account 0 private key)
 *   NODE_URL_728126428           — Tron mainnet full node URL
 *   NODE_URL_3448148188          — Tron Nile testnet full node URL
 *   SP1_CONSENSUS_RPC            — Ethereum beacon chain RPC URL (e.g. https://lodestar-mainnet.chainsafe.io)
 *   TRON_FEE_LIMIT               — optional, in sun (default: 100000000 = 100 TRX)
 *
 * Options:
 *   --testnet          — use Tron Nile testnet (default: mainnet)
 *
 * Usage:
 *   yarn tron-update-sp1-helios <sp1-helios-address> [--testnet]
 */

import "dotenv/config";
import { createHash } from "crypto";
import { TronWeb } from "tronweb";
import { resolveChainId, TRON_MAINNET_CHAIN_ID, TRON_TESTNET_CHAIN_ID } from "../deploy";

const POLL_INTERVAL_MS = 3000;
const MAX_POLL_ATTEMPTS = 40;
const SLOTS_PER_PERIOD = 8192;

const TRONSCAN_URLS: Record<string, string> = {
  [TRON_MAINNET_CHAIN_ID]: "https://tronscan.org",
  [TRON_TESTNET_CHAIN_ID]: "https://nile.tronscan.org",
};

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

/** Call a view function on a Tron contract and return the raw hex result. */
async function tronCall(fullNode: string, contract: string, selector: string, parameter = ""): Promise<string> {
  await sleep(2000); // Avoid TronGrid rate limits (3 req/s for unauthenticated).
  const res = await fetch(`${fullNode}/wallet/triggerconstantcontract`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      owner_address: contract,
      contract_address: contract,
      function_selector: selector,
      parameter,
    }),
  });
  const data = await res.json();
  const result = data.constant_result?.[0];
  if (!result) throw new Error(`tronCall(${selector}) failed: ${JSON.stringify(data)}`);
  return result;
}

/** SHA-256 hash (SSZ uses SHA-256). */
function sha256(data: Buffer): Buffer {
  return createHash("sha256").update(data).digest();
}

/** Compute SSZ hash_tree_root of a SyncCommittee from its pubkeys and aggregate_pubkey. */
function computeSyncCommitteeHash(pubkeys: string[], aggregatePubkey: string): string {
  // Merkleize individual pubkey roots.
  const pubkeyRoots = pubkeys.map((pk) => {
    const bytes = Buffer.from(pk.replace("0x", ""), "hex");
    const padded = Buffer.concat([bytes, Buffer.alloc(16)]); // 48 -> 64 bytes
    return sha256(Buffer.concat([padded.subarray(0, 32), padded.subarray(32, 64)]));
  });

  // Merkleize 512 roots (already a power of 2).
  let layer = pubkeyRoots;
  while (layer.length > 1) {
    const next: Buffer[] = [];
    for (let i = 0; i < layer.length; i += 2) next.push(sha256(Buffer.concat([layer[i], layer[i + 1]])));
    layer = next;
  }
  const pubkeysRoot = layer[0];

  // Hash aggregate pubkey.
  const aggBytes = Buffer.from(aggregatePubkey.replace("0x", ""), "hex");
  const aggPadded = Buffer.concat([aggBytes, Buffer.alloc(16)]);
  const aggRoot = sha256(Buffer.concat([aggPadded.subarray(0, 32), aggPadded.subarray(32, 64)]));

  // SyncCommittee root = sha256(pubkeys_root || aggregate_pubkey_root).
  return "0x" + sha256(Buffer.concat([pubkeysRoot, aggRoot])).toString("hex");
}

/** Fetch the sync committee hash for a given period from a beacon chain RPC. */
async function fetchSyncCommitteeHash(consensusRpc: string, period: number): Promise<string> {
  // The light client update for (period - 1) contains next_sync_committee for `period`.
  const url = `${consensusRpc}/eth/v1/beacon/light_client/updates?start_period=${period - 1}&count=1`;
  const res = await fetch(url);
  if (!res.ok) throw new Error(`Beacon API error: ${res.status} ${await res.text()}`);
  const data = await res.json();
  const nsc = data[0]?.data?.next_sync_committee;
  if (!nsc?.pubkeys?.length) throw new Error("No next_sync_committee in beacon response");
  return computeSyncCommitteeHash(nsc.pubkeys, nsc.aggregate_pubkey);
}

async function waitForConfirmation(tronWeb: TronWeb, txID: string): Promise<any> {
  for (let i = 0; i < MAX_POLL_ATTEMPTS; i++) {
    await new Promise((r) => setTimeout(r, POLL_INTERVAL_MS));
    const txInfo = await tronWeb.trx.getTransactionInfo(txID);
    if (txInfo && (txInfo as any).id) return txInfo;
    console.log(`  Waiting... (${i + 1}/${MAX_POLL_ATTEMPTS})`);
  }
  console.log("Error: not confirmed within timeout.");
  process.exit(1);
}

async function main(): Promise<void> {
  const args = process.argv.slice(2).filter((a) => !a.startsWith("-"));
  const sp1HeliosAddress = args[0];
  if (!sp1HeliosAddress) {
    console.log("Usage: yarn tron-update-sp1-helios <sp1-helios-address> [--testnet]");
    process.exit(1);
  }

  const chainId = resolveChainId();
  const feeLimit = parseInt(process.env.TRON_FEE_LIMIT || "100000000", 10);
  const mnemonic = process.env.MNEMONIC;
  const fullNode = process.env[`NODE_URL_${chainId}`];
  const consensusRpc = process.env.SP1_CONSENSUS_RPC;

  if (!mnemonic) {
    console.log("Error: MNEMONIC env var is required.");
    process.exit(1);
  }
  if (!fullNode) {
    console.log(`Error: NODE_URL_${chainId} env var is required.`);
    process.exit(1);
  }
  if (!consensusRpc) {
    console.log("Error: SP1_CONSENSUS_RPC env var is required.");
    process.exit(1);
  }

  // Set up TronWeb with derived private key.
  const tronWeb = new TronWeb({ fullHost: fullNode });
  const { ethersHDNodeWallet, Mnemonic } = tronWeb.utils.ethersUtils;
  const wallet = ethersHDNodeWallet.fromMnemonic(Mnemonic.fromPhrase(mnemonic), "m/44'/60'/0'/0/0");
  tronWeb.setPrivateKey(wallet.privateKey.slice(2));
  const sender = tronWeb.address.fromPrivateKey(wallet.privateKey.slice(2)) as string;

  // Convert Tron address to 41-prefixed hex for API calls.
  const contractHex = TronWeb.address.toHex(sp1HeliosAddress);

  console.log("=== SP1Helios Update ===");
  console.log(`Contract:      ${sp1HeliosAddress}`);
  console.log(`Sender:        ${sender}`);
  console.log(`Chain ID:      ${chainId}`);
  console.log(`Consensus RPC: ${consensusRpc}`);

  // --- Step 1: Read on-chain state ---
  console.log("\n--- Reading on-chain state ---");

  const headHex = await tronCall(fullNode, contractHex, "head()");
  const head = parseInt(headHex, 16);
  const headPadded = head.toString(16).padStart(64, "0");

  const prevHeader = "0x" + (await tronCall(fullNode, contractHex, "headers(uint256)", headPadded));

  const genesisTimeHex = await tronCall(fullNode, contractHex, "GENESIS_TIME()");
  const genesisTime = parseInt(genesisTimeHex, 16);

  const secondsPerSlotHex = await tronCall(fullNode, contractHex, "SECONDS_PER_SLOT()");
  const secondsPerSlot = parseInt(secondsPerSlotHex, 16);

  const currentPeriod = Math.floor(head / SLOTS_PER_PERIOD);
  const periodPadded = currentPeriod.toString(16).padStart(64, "0");
  const startSyncCommitteeHash =
    "0x" + (await tronCall(fullNode, contractHex, "syncCommittees(uint256)", periodPadded));

  const slotTimestamp = genesisTime + head * secondsPerSlot;
  const now = Math.floor(Date.now() / 1000);
  const remaining = 7 * 86400 - (now - slotTimestamp);

  console.log(`  head:                   ${head} (period ${currentPeriod})`);
  console.log(`  headers[head]:          ${prevHeader}`);
  console.log(`  startSyncCommitteeHash: ${startSyncCommitteeHash}`);
  console.log(`  Time remaining:         ${(remaining / 86400).toFixed(1)} days`);

  if (remaining <= 0) {
    console.log("\nError: MAX_SLOT_AGE already exceeded. Contract cannot be updated.");
    process.exit(1);
  }

  // --- Step 2: Compute target newHead ---
  const currentSlot = Math.floor((now - genesisTime) / secondsPerSlot);
  const newHead = currentSlot - 64; // ~2 epochs behind head for finality
  const newPeriod = Math.floor(newHead / SLOTS_PER_PERIOD);

  console.log(`\n--- Target ---`);
  console.log(`  newHead:    ${newHead} (period ${newPeriod})`);

  // --- Step 3: Fetch sync committee hash for the new period ---
  console.log(`\n--- Fetching sync committee hash for period ${newPeriod} ---`);
  const syncCommitteeHash = await fetchSyncCommitteeHash(consensusRpc, newPeriod);
  console.log(`  syncCommitteeHash: ${syncCommitteeHash}`);

  // --- Step 4: Encode and send update ---
  console.log("\n--- Sending update transaction ---");

  // Placeholder values for fields that are stored as-is for new slots.
  const newHeader = "0x" + "bb".repeat(32);
  const executionStateRoot = "0x" + "cc".repeat(32);
  const nextSyncCommitteeHash = "0x" + "00".repeat(32);

  // ABI-encode ProofOutputs struct.
  const publicValues = tronWeb.utils.abi.encodeParams(
    ["(bytes32,bytes32,bytes32,uint256,bytes32,uint256,bytes32,bytes32,(bytes32,bytes32,address)[])"],
    [
      [
        executionStateRoot,
        newHeader,
        nextSyncCommitteeHash,
        newHead,
        prevHeader,
        head,
        syncCommitteeHash,
        startSyncCommitteeHash,
        [],
      ],
    ]
  );

  // ABI-encode the outer update(bytes,bytes) parameters.
  // encodeParams returns 0x-prefixed hex, so pass publicValues directly.
  const rawParameter = tronWeb.utils.abi.encodeParams(["bytes", "bytes"], ["0x", publicValues]);

  const tx = await tronWeb.transactionBuilder.triggerSmartContract(
    sp1HeliosAddress,
    "update(bytes,bytes)",
    { feeLimit, rawParameter },
    [],
    sender
  );

  if (!tx.result?.result) {
    console.log("Error: transaction build failed:", JSON.stringify(tx, null, 2));
    process.exit(1);
  }

  const signed = await tronWeb.trx.sign(tx.transaction);
  const result = await tronWeb.trx.sendRawTransaction(signed);

  if (!result.result) {
    console.log("Error: broadcast failed:", JSON.stringify(result, null, 2));
    process.exit(1);
  }

  const txID: string = (result as any).transaction?.txID || (result as any).txid;
  console.log(`  TX sent: ${txID}`);

  const txInfo = await waitForConfirmation(tronWeb, txID);
  const tronscanBase = TRONSCAN_URLS[chainId] || "https://tronscan.org";

  if (txInfo.receipt?.result !== "SUCCESS") {
    console.log("Error: transaction failed:", JSON.stringify(txInfo, null, 2));
    process.exit(1);
  }

  console.log(`\nUpdate successful!`);
  console.log(`  New head: ${newHead} (period ${newPeriod})`);
  console.log(`  TX ID:    ${txID}`);
  console.log(`  Tronscan: ${tronscanBase}/#/transaction/${txID}`);
  console.log(`  Energy:   ${txInfo.receipt?.energy_usage_total || "unknown"}`);
}

main().catch((err) => {
  console.log("Fatal error:", err.message || err);
  process.exit(1);
});
