// This script reclaims used nonce accounts created on the sponsored CCTP bridge.

import * as anchor from "@coral-xyz/anchor";
import { AnchorProvider } from "@coral-xyz/anchor";
import yargs from "yargs";
import { hideBin } from "yargs/helpers";
import { getSponsoredCctpSrcPeripheryProgram, readProgramEvents } from "../../../src/svm/web3-v1";
import { PublicKey, Transaction } from "@solana/web3.js";

// Set up the provider
const provider = AnchorProvider.env();
anchor.setProvider(provider);
const program = getSponsoredCctpSrcPeripheryProgram(provider);
const programId = program.programId;

// Parse arguments
const argvPromise = yargs(hideBin(process.argv))
  .option("from", {
    type: "number",
    demandOption: false,
    default: 0,
    describe: "Filter deposits from this timestamp (in seconds since epoch)",
  })
  .option("to", {
    type: "number",
    demandOption: false,
    describe: "Filter deposits to this timestamp (in seconds since epoch)",
  }).argv;

async function reclaimUsedNonceAccounts(): Promise<void> {
  const argv = await argvPromise;
  const fromTs = argv.from;

  const txPayer = provider.wallet.payer;
  if (!txPayer) {
    throw new Error("Provider wallet does not have a keypair");
  }

  const latestSlot = await provider.connection.getSlot("finalized");
  const latestBlockTime = await provider.connection.getBlockTime(latestSlot);
  if (!latestBlockTime) {
    throw new Error("Could not fetch latest block time");
  }

  const toTs = argv.to || latestBlockTime;

  const events = await readProgramEvents(provider.connection, program);
  const depositEvents = events.filter((event) => {
    return event.blockTime >= fromTs && event.blockTime <= toTs && event.name === "sponsoredDepositForBurn";
  });

  if (depositEvents.length === 0) {
    console.log("No deposit events found for the given time range.");
    return;
  }

  console.log("Sponsored deposit events fetched successfully.");
  for (const event of depositEvents) {
    const quoteNonce: Buffer = event.data.quoteNonce;
    const [usedNonce] = PublicKey.findProgramAddressSync([Buffer.from("used_nonce"), quoteNonce], programId);
    const usedNonceAccount = await provider.connection.getAccountInfo(usedNonce);
    if (!usedNonceAccount) {
      console.log(`Used nonce account ${usedNonce.toString()} does not exist, skipping.`);
      continue;
    }

    console.log(`Sponsored deposit with used nonce 0x${quoteNonce.toString("hex")}:`);
    const quoteDeadline: number = event.data.quoteDeadline.toNumber();
    if (quoteDeadline >= latestBlockTime) {
      console.log(
        `- skipping used nonce account ${usedNonce.toString()} from tx ${
          event.signature
        } which can be closed only after ${new Date(quoteDeadline * 1000).toUTCString()}`
      );
      continue;
    }

    console.log(`-reclaiming used nonce account ${usedNonce.toString()}`);
    const ix = await program.methods.reclaimUsedNonceAccount({ nonce: Array.from(quoteNonce) }).instruction();
    const tx = new Transaction().add(ix);
    const txSignature = await provider.sendAndConfirm(tx, [txPayer], { commitment: "confirmed" });
    console.log(`-reclaimed used nonce account ${usedNonce.toString()}, transaction signature: ${txSignature}`);
  }
}

reclaimUsedNonceAccounts();
