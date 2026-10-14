// This script queries the events of the spoke pool and prints them in a human readable format.
import { AnchorProvider, Program } from "@anchor-lang/core";
import { PublicKey } from "@solana/web3.js";
import { stringifyCpiEvent } from "../../src/svm/web3-v1";
import { SvmSpokeIdl } from "../../src/svm/assets";
import yargs from "yargs";
import { hideBin } from "yargs/helpers";
import { readEventsForAddress } from "./utils/events";

async function main(): Promise<void> {
  const argv = await yargs(hideBin(process.argv))
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
    })
    .option("jsonl", {
      type: "boolean",
      default: false,
      describe: "Stream events with signature and slot as JSON lines",
    }).argv;
  const program = new Program(
    { ...SvmSpokeIdl, address: new PublicKey(argv.programId).toBase58() },
    AnchorProvider.env()
  );
  await queryEvents(program, argv.eventName || "any", argv.jsonl);
}

export async function queryEvents(program: Program<any>, eventName: string, jsonl: boolean): Promise<void> {
  const formattedEvents = [];
  for await (const event of readEventsForAddress(program.provider.connection, program, program.programId)) {
    // Keep the existing PascalCase CLI choices while Anchor exposes camelCase names.
    if (eventName !== "any" && event.name.toLowerCase() !== eventName.toLowerCase()) continue;
    const data = stringifyCpiEvent(event.data, event.name);
    if (jsonl) console.log(JSON.stringify({ name: event.name, signature: event.signature, slot: event.slot, data }));
    else formattedEvents.push(data);
  }

  if (!jsonl) console.log(JSON.stringify(formattedEvents, null, 2));
}

if (require.main === module) {
  main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
  });
}
