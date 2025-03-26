// This script fetches all deposits for a given spoke pool.

import * as anchor from "@coral-xyz/anchor";
import { AnchorProvider, BN } from "@coral-xyz/anchor";
import { PublicKey } from "@solana/web3.js";
import yargs from "yargs";
import { hideBin } from "yargs/helpers";
import { getSpokePoolProgram, readProgramEvents } from "../../src/svm/web3-v1";

// Set up the provider
const provider = AnchorProvider.env();
anchor.setProvider(provider);
const program = getSpokePoolProgram(provider);
const programId = program.programId;
console.log("SVM-Spoke Program ID:", programId.toString());

// Parse arguments
const argvPromise = yargs(hideBin(process.argv)).option("seed", {
  type: "string",
  demandOption: true,
  describe: "Seed for the state account PDA",
}).argv;

async function queryDeposits(): Promise<void> {
  const argv = await argvPromise;
  const seed = new BN(argv.seed);

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
    const depositEvents = events.filter((event) => event.name === "fundsDeposited");

    if (depositEvents.length === 0) {
      console.log("No deposit events found for the given seed.");
      return;
    }

    console.log("Deposit events fetched successfully:");
    depositEvents.forEach((event, index) => {
      console.log(`Deposit Event ${index + 1}:`);
      console.table([
        { Property: "inputToken", Value: new PublicKey(event.data.inputToken).toString() },
        { Property: "outputToken", Value: new PublicKey(event.data.outputToken).toString() },
        { Property: "inputAmount", Value: event.data.inputAmount.toString() },
        { Property: "outputAmount", Value: event.data.outputAmount.toString() },
        { Property: "destinationChainId", Value: event.data.destinationChainId.toString() },
        { Property: "depositId", Value: event.data.depositId.toString() },
        { Property: "quoteTimestamp", Value: event.data.quoteTimestamp.toString() },
        { Property: "fillDeadline", Value: event.data.fillDeadline.toString() },
        { Property: "exclusivityDeadline", Value: event.data.exclusivityDeadline.toString() },
        { Property: "depositor", Value: new PublicKey(event.data.depositor).toString() },
        { Property: "recipient", Value: new PublicKey(event.data.recipient).toString() },
        { Property: "exclusiveRelayer", Value: new PublicKey(event.data.exclusiveRelayer).toString() },
        { Property: "message", Value: event.data.message.toString() },
      ]);
    });
  } catch (error) {
    console.error("An error occurred while fetching the deposit events:", error);
  }
}

// Run the queryDeposits function
queryDeposits();
