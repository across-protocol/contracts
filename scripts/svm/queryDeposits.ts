// This script fetches all deposits for a given spoke pool.

import * as anchor from "@coral-xyz/anchor";
import { BN, Program, AnchorProvider } from "@coral-xyz/anchor";
import { PublicKey } from "@solana/web3.js";
import { SvmSpoke } from "../../target/types/svm_spoke";
import yargs from "yargs";
import { hideBin } from "yargs/helpers";
import { update, EventType, queryEventsBySlotRange } from "../../src/SvmEventUtils";

// Set up the provider
const provider = AnchorProvider.env();
anchor.setProvider(provider);
const idl = require("../../target/idl/svm_spoke.json");
const program = new Program<SvmSpoke>(idl, provider);
const programId = new PublicKey("YVMQN27RnCNt23NRxzJPumXRd8iovEfKtzkqyMc5vDt");
console.log("programId", programId.toString());

// Parse arguments
const argvPromise = yargs(hideBin(process.argv)).option("seed", {
  type: "string",
  demandOption: true,
  describe: "Seed for the state account PDA",
}).argv;

const eventStore = new Map<number, EventType[]>();

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
    // Measure the time taken by the update function
    console.time("Update Function Duration");
    await update(provider.connection, program, eventStore);
    console.timeEnd("Update Function Duration");

    // console.log("events", events);
    // console.log("eventStore", eventStore);

    const v3FundsDepositedEvents = queryEventsBySlotRange("v3FundsDeposited", eventStore, 342975519, 342975519);

    console.log("v3FundsDepositedEvents", v3FundsDepositedEvents);

    // const depositEvents = Array.from(eventStore).filter((event) => event.name === "v3FundsDeposited");

    // if (depositEvents.length === 0) {
    //   console.log("No deposit events found for the given seed.");
    //   return;
    // }

    // console.log("Deposit events fetched successfully:");
    // depositEvents.forEach((event, index) => {
    //   console.log(`Deposit Event ${index + 1}:`);
    //   console.table([
    //     { Property: "inputToken", Value: new PublicKey(event.data.inputToken).toString() },
    //     { Property: "outputToken", Value: new PublicKey(event.data.outputToken).toString() },
    //     { Property: "inputAmount", Value: event.data.inputAmount.toString() },
    //     { Property: "outputAmount", Value: event.data.outputAmount.toString() },
    //     { Property: "destinationChainId", Value: event.data.destinationChainId.toString() },
    //     { Property: "depositId", Value: event.data.depositId.toString() },
    //     { Property: "quoteTimestamp", Value: event.data.quoteTimestamp.toString() },
    //     { Property: "fillDeadline", Value: event.data.fillDeadline.toString() },
    //     { Property: "exclusivityDeadline", Value: event.data.exclusivityDeadline.toString() },
    //     { Property: "depositor", Value: new PublicKey(event.data.depositor).toString() },
    //     { Property: "recipient", Value: new PublicKey(event.data.recipient).toString() },
    //     { Property: "exclusiveRelayer", Value: new PublicKey(event.data.exclusiveRelayer).toString() },
    //     { Property: "message", Value: event.data.message.toString() },
    //   ]);
    // });
  } catch (error) {
    console.error("An error occurred while fetching the deposit events:", error);
  }
}

// Run the queryDeposits function
queryDeposits();
