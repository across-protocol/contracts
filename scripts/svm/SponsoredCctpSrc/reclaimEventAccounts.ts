// This script reclaims used nonce accounts created on the sponsored CCTP bridge.

import * as anchor from "@coral-xyz/anchor";
import { AnchorProvider, BN } from "@coral-xyz/anchor";
import yargs from "yargs";
import { hideBin } from "yargs/helpers";
import {
  CIRCLE_IRIS_API_URL_DEVNET,
  CIRCLE_IRIS_API_URL_MAINNET,
  decodeMessageSentDataV2,
  EVENT_ACCOUNT_WINDOW_SECONDS,
  findProgramAddress,
  getMessageTransmitterV2Program,
  getSponsoredCctpSrcPeripheryProgram,
  getV2BurnAttestation,
  intToU8Array32,
  isSolanaDevnet,
  readProgramEvents,
} from "../../../src/svm/web3-v1";
import { ComputeBudgetProgram, PublicKey, Transaction } from "@solana/web3.js";

// Set up the provider and programs
const provider = AnchorProvider.env();
anchor.setProvider(provider);
const program = getSponsoredCctpSrcPeripheryProgram(provider);
const programId = program.programId;
const messageTransmitterV2Program = getMessageTransmitterV2Program(provider);

const messageTransmitter = findProgramAddress("message_transmitter", messageTransmitterV2Program.programId).publicKey;

const irisApiUrl = isSolanaDevnet(provider) ? CIRCLE_IRIS_API_URL_DEVNET : CIRCLE_IRIS_API_URL_MAINNET;

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

async function reclaimEventAccounts(): Promise<void> {
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
  const createdEvents = events.filter((event) => {
    return event.blockTime >= fromTs && event.blockTime <= toTs && event.name === "createdEventAccount";
  });

  if (createdEvents.length === 0) {
    console.log("No MessageSent creation events found for the given time range.");
    return;
  }

  console.log("MessageSent creation events fetched successfully.");
  for (const event of createdEvents) {
    const messageSentEventData: PublicKey = event.data.messageSentEventData;
    const messageSentAccount = await provider.connection.getAccountInfo(messageSentEventData);
    if (!messageSentAccount) {
      console.log(`MessageSent account ${messageSentEventData.toString()} does not exist, skipping.`);
      continue;
    }
    const { createdAt, message } = await messageTransmitterV2Program.account.messageSent.fetch(messageSentEventData);

    const canCloseAfter = createdAt.toNumber() + EVENT_ACCOUNT_WINDOW_SECONDS;
    if (canCloseAfter >= latestBlockTime) {
      console.log(
        `Skipping MessageSent event event account ${messageSentEventData.toString()} from tx ${
          event.signature
        } which can be closed only after ${new Date(canCloseAfter * 1000).toUTCString()}`
      );
      continue;
    }

    const attestationResponse = await getV2BurnAttestation(event.signature, message, irisApiUrl);
    if (!attestationResponse) {
      console.log(`No matching attestation found for MessageSent event in tx ${event.signature}, skipping.`);
      continue;
    }
    console.log(`Found matching attestation for MessageSent event in tx ${event.signature}, trying to reclaim:`);

    // Encode instruction parameters from decoded destination message.
    const destinationMessage = decodeMessageSentDataV2(attestationResponse.destinationMessage);
    const finalityThresholdExecutedBuffer = Buffer.alloc(4);
    finalityThresholdExecutedBuffer.writeUInt32BE(destinationMessage.finalityThresholdExecuted, 0);
    const reclaimEventAccountParams = {
      attestation: attestationResponse.attestation,
      nonce: intToU8Array32(new BN(destinationMessage.nonce.toString())),
      finalityThresholdExecuted: Array.from(finalityThresholdExecutedBuffer),
      feeExecuted: intToU8Array32(new BN(destinationMessage.messageBody.feeExecuted.toString())),
      expirationBlock: intToU8Array32(new BN(destinationMessage.messageBody.expirationBlock.toString())),
    };

    const reclaimIx = await program.methods
      .reclaimEventAccount(reclaimEventAccountParams)
      .accounts({ messageTransmitter, messageSentEventData, program: programId })
      .instruction();
    const computeBudgetIx = ComputeBudgetProgram.setComputeUnitLimit({ units: 250_000 });

    const tx = new Transaction().add(computeBudgetIx, reclaimIx);
    const txSignature = await provider.sendAndConfirm(tx, [txPayer], { commitment: "confirmed" });
    console.log(`-reclaimed event account ${messageSentEventData.toString()}, transaction signature: ${txSignature}`);
  }
}

reclaimEventAccounts();
