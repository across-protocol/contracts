// This script finds the associated Fill Status PDA from a fill OR deposit event by re-deriving it without doing any
// // on-chain calls. Note the props required are present in both deposit and fill events.
// Example usage:
// anchor run findFillStatusPdaFromFill -- \
//  --input_token "0x1c7d4b196cb0c7b01d743fbc6116a902379c7238" \
//  --output_token "wBeYLVBabtv4cyb7RyMmRxvRSkRsCP4PMBCJRw66kKC" \
//  --input_amount "1" \
//  --output_amount "1" \
//  --repayment_chain_id "133268194659241" \
//  --origin_chain_id "11155111" \
//  --deposit_id "0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,4,98" \
//  --fill_deadline 1740569770 \
//  --exclusivity_deadline 1740569740 \
//  --exclusive_relayer "0x0000000000000000000000000000000000000000" \
//  --depositor "0x9a8f92a830a5cb89a3816e3d267cb7791c16b04d" \
//  --recipient "5HRmK3G6BzWAtF22dBgoTiPGVovSmG4rLvVQoUhum9FJ" \
//  --message_hash "0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0"

import * as anchor from "@coral-xyz/anchor";
import { PublicKey } from "@solana/web3.js";
import { BN } from "@coral-xyz/anchor";
import yargs from "yargs";
import { hideBin } from "yargs/helpers";
import {
  calculateRelayEventHashUint8Array,
  getSpokePoolProgram,
  evmAddressToPublicKey,
  intToU8Array32,
} from "../../src/svm/web3-v1";

// Set up the provider
const provider = anchor.AnchorProvider.env();
anchor.setProvider(provider);
const program = getSpokePoolProgram(provider);
const programId = program.programId;

// Parse arguments
const argv = yargs(hideBin(process.argv))
  .option("input_token", { type: "string", demandOption: true, describe: "Input token address" })
  .option("output_token", { type: "string", demandOption: true, describe: "Output token address" })
  .option("input_amount", { type: "string", demandOption: true, describe: "Input amount" })
  .option("output_amount", { type: "string", demandOption: true, describe: "Output amount" })
  .option("repayment_chain_id", { type: "string", demandOption: true, describe: "Repayment chain ID" })
  .option("origin_chain_id", { type: "string", demandOption: true, describe: "Origin chain ID" })
  .option("deposit_id", { type: "string", demandOption: true, describe: "Deposit ID" })
  .option("fill_deadline", { type: "number", demandOption: true, describe: "Fill deadline" })
  .option("exclusivity_deadline", { type: "number", demandOption: true, describe: "Exclusivity deadline" })
  .option("exclusive_relayer", { type: "string", demandOption: true, describe: "Exclusive relayer address" })
  .option("depositor", { type: "string", demandOption: true, describe: "Depositor address" })
  .option("recipient", { type: "string", demandOption: true, describe: "Recipient address" })
  .option("message_hash", { type: "string", demandOption: true, describe: "Message hash" }).argv;

async function findFillStatusPda() {
  const resolvedArgv = await argv;
  const relayEventData = {
    depositor: convertAddress(resolvedArgv.depositor),
    recipient: convertAddress(resolvedArgv.recipient),
    exclusiveRelayer: convertAddress(resolvedArgv.exclusive_relayer),
    inputToken: convertAddress(resolvedArgv.input_token),
    outputToken: convertAddress(resolvedArgv.output_token),
    inputAmount: intToU8Array32(new BN(resolvedArgv.input_amount)),
    outputAmount: new BN(resolvedArgv.output_amount),
    originChainId: new BN(resolvedArgv.origin_chain_id),
    depositId: parseStringToUint8Array(resolvedArgv.deposit_id),
    fillDeadline: resolvedArgv.fill_deadline,
    exclusivityDeadline: resolvedArgv.exclusivity_deadline,
    messageHash: parseStringToUint8Array(resolvedArgv.message_hash),
  };

  console.log("finding fill status pda for relay event data:");
  console.table(Object.entries(relayEventData).map(([key, value]) => ({ Property: key, Value: value.toString() })));

  const chainId = new BN(resolvedArgv.repayment_chain_id);
  const relayHashUint8Array = calculateRelayEventHashUint8Array(relayEventData, chainId);
  const [fillStatusPda] = PublicKey.findProgramAddressSync([Buffer.from("fills"), relayHashUint8Array], programId);
  console.log("Fill Status PDA Address:", fillStatusPda.toString());
}

findFillStatusPda().catch(console.error);

function convertAddress(address: string) {
  if (address.startsWith("0x")) return evmAddressToPublicKey(address);
  return new PublicKey(address);
}

function parseStringToUint8Array(inputString: string): Uint8Array {
  const numberArray = inputString.split(",").map(Number);
  return new Uint8Array(numberArray);
}
