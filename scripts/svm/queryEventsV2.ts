// This script queries the events of the spoke pool and prints them in a human readable format.
import { AnchorProvider } from "@coral-xyz/anchor";
import { address, createSolanaRpc } from "@solana/web3-v2.js";
import yargs from "yargs";
import { hideBin } from "yargs/helpers";
import { readProgramEventsV2, stringifyCpiEvent, SvmSpokeIdl } from "../../src/svm";

// Set up the provider
const provider = AnchorProvider.env();

const argvPromise = yargs(hideBin(process.argv))
  .option("eventName", {
    type: "string",
    demandOption: false,
    describe: "Name of the event to query",
    choices: [
      "any",
      "FilledV3Relay",
      "V3FundsDeposited",
      "EnabledDepositRoute",
      "RelayedRootBundle",
      "ExecutedRelayerRefundRoot",
      "BridgedToHubPool",
      "PausedDeposits",
      "PausedFills",
      "SetXDomainAdmin",
      "EmergencyDeletedRootBundle",
      "RequestedV3SlowFill",
      "ClaimedRelayerRefund",
      "TokensBridged",
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
  const programId = argv.programId;
  const rpc = createSolanaRpc(provider.connection.rpcEndpoint);
  const events = await readProgramEventsV2(rpc, address(programId), SvmSpokeIdl, "confirmed");
  const filteredEvents = events.filter((event) => (eventName == "any" ? true : event.name == eventName));
  const formattedEvents = filteredEvents.map((event) => stringifyCpiEvent(event));

  console.log(JSON.stringify(formattedEvents, null, 2));
}

// Run the queryEvents function
queryEvents();
