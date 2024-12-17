// This script queries the events of the spoke pool and prints them in a human readable format.
import * as anchor from "@coral-xyz/anchor";
import { AnchorProvider, BN, Program } from "@coral-xyz/anchor";
import { publicKeyToEvmAddress, readProgramEvents } from "../../src/svm";
import { SvmSpoke } from "../../target/types/svm_spoke";
import { BigNumber } from "ethers";
import yargs from "yargs";
import { hideBin } from "yargs/helpers";

// Set up the provider
const provider = AnchorProvider.env();
anchor.setProvider(provider);
const idl = require("../../target/idl/svm_spoke.json");
const program = new Program<SvmSpoke>(idl, provider);
const programId = program.programId;
console.log("SVM-Spoke Program ID:", programId.toString());

function deepStringify(obj: any): any {
  if (BN.isBN(obj) || BigNumber.isBigNumber(obj) || obj?.constructor?.toString()?.includes("PublicKey")) {
    if (obj.toString().includes("111111111111")) {
      return publicKeyToEvmAddress(obj);
    }
    return obj.toString();
  } else if (Array.isArray(obj) && obj.length == 32) {
    return Buffer.from(obj).toString("hex");
  } else if (Array.isArray(obj)) {
    return obj.map(deepStringify);
  } else if (obj !== null && typeof obj === "object") {
    return Object.fromEntries(Object.entries(obj).map(([key, value]) => [key, deepStringify(value)]));
  }
  return obj;
}

const argvPromise = yargs(hideBin(process.argv)).option("eventName", {
  type: "string",
  demandOption: false,
  describe: "Name of the event to query",
  choices: [
    "any",
    "filledV3Relay",
    "v3FundsDeposited",
    "enabledDepositRoute",
    "relayedRootBundle",
    "executedRelayerRefundRoot",
    "bridgedToHubPool",
    "pausedDeposits",
    "pausedFills",
    "setXDomainAdmin",
    "emergencyDeletedRootBundle",
    "requestedV3SlowFill",
    "claimedRelayerRefund",
    "tokensBridged",
  ],
}).argv;

// Parse argument
async function queryEvents(): Promise<void> {
  const argv = await argvPromise;
  const eventName = argv.eventName || "any";
  const events = await readProgramEvents(provider.connection, program, "confirmed");
  const filteredEvents = events.filter((event) => (eventName == "any" ? true : event.name == eventName));
  const formattedEvents = filteredEvents.map((event) => deepStringify(event));
  console.log(JSON.stringify(formattedEvents, null, 2));
}

// Run the queryState function
queryEvents();
