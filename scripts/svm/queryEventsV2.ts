// This script queries the events of the spoke pool and prints them in a human readable format.
import { AnchorProvider, Program } from "@anchor-lang/core";
import { PublicKey } from "@solana/web3.js";
import { stringifyCpiEvent } from "../../src/svm/web3-v1";
import { SvmSpokeIdl } from "../../src/svm/assets";
import yargs from "yargs";
import { hideBin } from "yargs/helpers";
import { readEventsForAddress } from "./utils/events";

// Set up the provider
const provider = AnchorProvider.env();

const argvPromise = yargs(hideBin(process.argv))
  .option("eventName", {
    type: "string",
    demandOption: false,
    describe: "Name of the event to query",
    choices: [
      "any",
      "FilledRelay",
      "FundsDeposited",
      "EnabledDepositRoute",
      "RelayedRootBundle",
      "ExecutedRelayerRefundRoot",
      "PausedDeposits",
      "PausedFills",
      "SetXDomainAdmin",
      "EmergencyDeletedRootBundle",
      "RequestedSlowFill",
      "ClaimedRelayerRefund",
    ],
  })
  .option("programId", {
    type: "string",
    demandOption: true,
    describe: "SvmSpokeProgram ID to query events from",
  }).argv;

async function queryEvents(): Promise<void> {
  const argv = await argvPromise;
  const eventName = argv.eventName || "any";
  const { programId } = argv;
  const program = new Program({ ...SvmSpokeIdl, address: new PublicKey(programId).toBase58() }, provider);
  const formattedEvents = [];
  for await (const event of readEventsForAddress(provider.connection, program, program.programId)) {
    // Keep the existing PascalCase CLI choices while Anchor exposes camelCase names.
    if (eventName === "any" || event.name.toLowerCase() === eventName.toLowerCase())
      formattedEvents.push(stringifyCpiEvent(event.data, event.name));
  }

  console.log(JSON.stringify(formattedEvents, null, 2));
}

// Run the queryEvents function
queryEvents().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
