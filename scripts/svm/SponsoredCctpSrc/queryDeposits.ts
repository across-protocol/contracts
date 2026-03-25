// This script fetches deposits on the sponsored CCTP bridge.

import * as anchor from "@coral-xyz/anchor";
import { AnchorProvider } from "@coral-xyz/anchor";
import yargs from "yargs";
import { hideBin } from "yargs/helpers";
import {
  getSponsoredCctpSrcPeripheryProgram,
  publicKeyToEvmAddress,
  readProgramEvents,
} from "../../../src/svm/web3-v1";

// Set up the provider
const provider = AnchorProvider.env();
anchor.setProvider(provider);
const program = getSponsoredCctpSrcPeripheryProgram(provider);

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

async function queryDeposits(): Promise<void> {
  const argv = await argvPromise;
  const fromTs = argv.from;

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

  console.log("Sponsored deposit events fetched successfully:");
  depositEvents.forEach((event, index) => {
    console.log(`Sponsored deposit event ${index + 1}:`);
    console.table([
      { Property: "slot", Value: event.slot },
      { Property: "blockTime", Value: event.blockTime },
      { Property: "txSignature", Value: event.signature },
      { Property: "quoteNonce", Value: "0x" + event.data.quoteNonce.toString("hex") },
      { Property: "originSender", Value: event.data.originSender.toString() },
      { Property: "finalRecipient", Value: publicKeyToEvmAddress(event.data.finalRecipient) },
      { Property: "quoteDeadline", Value: event.data.quoteDeadline.toNumber() },
      { Property: "maxBpsToSponsor", Value: event.data.maxBpsToSponsor.toNumber() },
      { Property: "maxUserSlippageBps", Value: event.data.maxUserSlippageBps.toNumber() },
      { Property: "finalToken", Value: publicKeyToEvmAddress(event.data.finalToken) },
      { Property: "quoteSignature", Value: "0x" + event.data.signature.toString("hex") },
    ]);
  });
}

queryDeposits();
