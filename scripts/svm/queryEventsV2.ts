// This script queries the events of the spoke pool and prints them in a human readable format.
import { AnchorProvider } from "@coral-xyz/anchor";
import { address, createSolanaRpc, createSolanaRpcSubscriptions } from "@solana/kit";
import { stringifyCpiEvent } from "../../src/svm/web3-v1";
import { SvmSpokeIdl } from "../../src/svm";
import yargs from "yargs";
import { hideBin } from "yargs/helpers";
import { readProgramEvents } from "../../src/svm";

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
      "BridgedToHubPool",
      "PausedDeposits",
      "PausedFills",
      "SetXDomainAdmin",
      "EmergencyDeletedRootBundle",
      "RequestedSlowFill",
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
  const { programId } = argv;
  const { rpcEndpoint } = provider.connection;

  const rpc = createSolanaRpc(rpcEndpoint);
  const rpcSubscriptions = createSolanaRpcSubscriptions(
    rpcEndpoint.replace(/^http(s?):\/\//i, (_m, s) => `ws${s ?? ""}://`)
  );

  const events = await readProgramEvents({ rpc, rpcSubscriptions }, address(programId), SvmSpokeIdl, "confirmed");

  const filteredEvents = events.filter((e) => (eventName === "any" ? true : e.name === eventName));
  const formattedEvents = filteredEvents.map((event) => stringifyCpiEvent(event.data, event.name));

  console.log(JSON.stringify(formattedEvents, null, 2));
}

// Run the queryEvents function
queryEvents();
