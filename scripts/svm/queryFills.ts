// This script fetches all fills for a given spoke pool.

import * as anchor from "@coral-xyz/anchor";
import { BN, Program, AnchorProvider } from "@coral-xyz/anchor";
import { PublicKey } from "@solana/web3.js";
import { SvmSpoke } from "../../target/types/svm_spoke";
import yargs from "yargs";
import { hideBin } from "yargs/helpers";
import { readProgramEvents } from "../../src/SvmUtils";

// Set up the provider
const provider = AnchorProvider.env();
anchor.setProvider(provider);
const idl = require("../../target/idl/svm_spoke.json");
const program = new Program<SvmSpoke>(idl, provider);
const programId = new PublicKey("YVMQN27RnCNt23NRxzJPumXRd8iovEfKtzkqyMc5vDt");

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
    console.log("events", events);
    const fillEvents = events.filter((event) => event.name === "filledV3Relay");

    if (fillEvents.length === 0) {
      console.log("No fill events found for the given seed.");
      return;
    }

    console.log("Fill events fetched successfully:");
    fillEvents.forEach((event, index) => {
      console.log(`Fill Event ${index + 1}:`);
      console.table([
        { Property: "inputToken", Value: new PublicKey(event.data.inputToken).toString() },
        { Property: "outputToken", Value: new PublicKey(event.data.outputToken).toString() },
        { Property: "inputAmount", Value: event.data.inputAmount.toString() },
        { Property: "outputAmount", Value: event.data.outputAmount.toString() },
        { Property: "repaymentChainId", Value: event.data.repaymentChainId.toString() },
        { Property: "originChainId", Value: event.data.originChainId.toString() },
        { Property: "depositId", Value: event.data.depositId.toString() },
        { Property: "fillDeadline", Value: event.data.fillDeadline.toString() },
        { Property: "exclusivityDeadline", Value: event.data.exclusivityDeadline.toString() },
        { Property: "exclusiveRelayer", Value: new PublicKey(event.data.exclusiveRelayer).toString() },
        { Property: "relayer", Value: new PublicKey(event.data.relayer).toString() },
        { Property: "depositor", Value: new PublicKey(event.data.depositor).toString() },
        { Property: "recipient", Value: new PublicKey(event.data.recipient).toString() },
        { Property: "message", Value: event.data.message.toString() },
        {
          Property: "updatedRecipient",
          Value: new PublicKey(event.data.relayExecutionInfo.updatedRecipient).toString(),
        },
        { Property: "updatedMessage", Value: event.data.relayExecutionInfo.updatedMessage.toString() },
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
