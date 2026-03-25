// This script fetches all fills for a given spoke pool.

import * as anchor from "@coral-xyz/anchor";
import { AnchorProvider, BN } from "@coral-xyz/anchor";
import { PublicKey } from "@solana/web3.js";
import yargs from "yargs";
import { hideBin } from "yargs/helpers";
import { getSpokePoolProgram, readProgramEvents, strPublicKey, u8Array32ToInt } from "../../src/svm/web3-v1";

// Set up the provider
const provider = AnchorProvider.env();
anchor.setProvider(provider);
const program = getSpokePoolProgram(provider);
const programId = program.programId;

// Parse arguments
const argv = yargs(hideBin(process.argv)).option("seed", {
  type: "string",
  demandOption: true,
  describe: "Seed for the state account PDA",
}).argv;

async function queryFills(): Promise<void> {
  const resolvedArgv = await argv;
  const seed = new BN(resolvedArgv.seed);

  // Define the state account PDA
  const [statePda, _] = PublicKey.findProgramAddressSync(
    [Buffer.from("state"), seed.toArrayLike(Buffer, "le", 8)],
    programId
  );

  console.table([
    { Property: "seed", Value: seed.toString() },
    { Property: "programId", Value: programId.toString() },
    { Property: "statePda", Value: statePda.toString() },
  ]);

  try {
    const events = await readProgramEvents(provider.connection, program);
    const fillEvents = events.filter((event) => event.name === "filledRelay");

    if (fillEvents.length === 0) {
      console.log("No fill events found for the given seed.");
      return;
    }
    console.log("Fill events fetched successfully:");
    fillEvents.forEach((event, index) => {
      console.log(`Fill Event ${index + 1}:`);
      console.table([
        { Property: "inputToken", Value: strPublicKey(event.data.inputToken) },
        { Property: "outputToken", Value: strPublicKey(event.data.outputToken) },
        { Property: "inputAmount", Value: u8Array32ToInt(event.data.inputAmount).toString() },
        { Property: "outputAmount", Value: event.data.outputAmount.toString() },
        { Property: "repaymentChainId", Value: event.data.repaymentChainId.toString() },
        { Property: "originChainId", Value: event.data.originChainId.toString() },
        { Property: "depositId", Value: event.data.depositId.toString() },
        { Property: "depositIdNum", Value: u8Array32ToInt(event.data.depositId).toString() },
        { Property: "fillDeadline", Value: event.data.fillDeadline.toString() },
        { Property: "exclusivityDeadline", Value: event.data.exclusivityDeadline.toString() },
        { Property: "exclusiveRelayer", Value: strPublicKey(event.data.exclusiveRelayer) },
        { Property: "relayer", Value: strPublicKey(event.data.relayer) },
        { Property: "depositor", Value: strPublicKey(event.data.depositor) },
        { Property: "recipient", Value: strPublicKey(event.data.recipient) },
        { Property: "messageHash", Value: event.data.messageHash.toString() },
        { Property: "updatedRecipient", Value: strPublicKey(event.data.relayExecutionInfo.updatedRecipient) },
        { Property: "updatedMessageHash", Value: event.data.relayExecutionInfo.updatedMessageHash.toString() },
        { Property: "updatedOutputAmount", Value: event.data.relayExecutionInfo.updatedOutputAmount.toString() },
        { Property: "fillType", Value: event.data.relayExecutionInfo.fillType },
      ]);
    });
  } catch (error) {
    console.error("An error occurred while fetching the fill events:", error);
  }
}

// Run the queryFills function
queryFills();
