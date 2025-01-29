// This script queries the events of the spoke pool and prints them in a human readable format.
import * as anchor from "@coral-xyz/anchor";
import { AnchorProvider, Program } from "@coral-xyz/anchor";
import yargs from "yargs";
import { hideBin } from "yargs/helpers";
import { readProgramEvents, stringifyCpiEvent } from "../../src/svm";
import { SvmSpoke } from "../../target/types/svm_spoke";

// Set up the provider
const provider = AnchorProvider.env();
anchor.setProvider(provider);
const idl = require("../../target/idl/svm_spoke.json");
const program = new Program<SvmSpoke>(idl, provider);
const programId = program.programId;
console.log("SVM-Spoke Program ID:", programId.toString());

const argvPromise = yargs(hideBin(process.argv)).option("eventName", {
  type: "string",
  demandOption: false,
  describe: "Name of the event to query",
  choices: [
    "any",
    "filledRelay",
    "fundsDeposited",
    "enabledDepositRoute",
    "relayedRootBundle",
    "executedRelayerRefundRoot",
    "bridgedToHubPool",
    "pausedDeposits",
    "pausedFills",
    "setXDomainAdmin",
    "emergencyDeletedRootBundle",
    "RequestedSlowFill",
    "claimedRelayerRefund",
    "tokensBridged",
  ],
}).argv;

async function queryEvents(): Promise<void> {
  const argv = await argvPromise;
  const eventName = argv.eventName || "any";
  const events = await readProgramEvents(provider.connection, program, "confirmed");
  const filteredEvents = events.filter((event) => (eventName == "any" ? true : event.name == eventName));
  const formattedEvents = filteredEvents.map((event) => stringifyCpiEvent(event));
  console.log(JSON.stringify(formattedEvents, null, 2));
}

// Run the queryEvents function
queryEvents();
