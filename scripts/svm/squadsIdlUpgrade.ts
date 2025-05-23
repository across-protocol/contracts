// This script prepares transaction for finalizing IDL upgrade and prints out Base58 encoded transaction that can be
// imported in the Squads transaction builder. This requires one first to have written the upgraded IDL to the buffer
// account (anchor idl write-buffer) and set its authority to the Squads multisig (anchor idl set-authority).

import { PublicKey } from "@solana/web3.js";
import yargs from "yargs";
import { hideBin } from "yargs/helpers";
import { AccountMeta, Transaction, TransactionInstruction } from "@solana/web3.js";
import { sha256 } from "@noble/hashes/sha2";
import bs58 from "bs58";

// Parse arguments
const argv = yargs(hideBin(process.argv))
  .option("programId", { type: "string", demandOption: true, describe: "Upgrade IDL for the given program ID" })
  .option("idlBuffer", { type: "string", demandOption: true, describe: "Buffer account where IDL has been written" })
  .option("closeRecipient", { type: "string", demandOption: true, describe: "Account to receive closed buffer SOL" })
  .option("multisig", { type: "string", demandOption: true, describe: "Multisig controlling the upgrade" }).argv;

async function squadsIdlUpgrade() {
  const resolvedArgv = await argv;
  const programId = new PublicKey(resolvedArgv.programId);
  const idlBuffer = new PublicKey(resolvedArgv.idlBuffer);
  const multisig = new PublicKey(resolvedArgv.multisig);
  const closeRecipient = new PublicKey(resolvedArgv.closeRecipient);

  // Get the deterministic IDL address for the program:
  const base = PublicKey.findProgramAddressSync([], programId)[0];
  const idlAddress = await PublicKey.createWithSeed(base, "anchor:idl", programId);

  console.log("Creating IDL upgrade transaction...");
  console.table([
    { Property: "programId", Value: programId.toString() },
    { Property: "idlBuffer", Value: idlBuffer.toString() },
    { Property: "idlAddress", Value: idlAddress.toString() },
    { Property: "multisig", Value: multisig.toString() },
    { Property: "closeRecipient", Value: closeRecipient.toString() },
  ]);

  const idlSetBufferAccounts: AccountMeta[] = [
    { pubkey: idlBuffer, isSigner: false, isWritable: true },
    { pubkey: idlAddress, isSigner: false, isWritable: true },
    { pubkey: multisig, isSigner: true, isWritable: false },
  ];
  const idlSetBufferInstructionData = Buffer.concat([
    Buffer.from(sha256("anchor:idl")).slice(0, 8).reverse(),
    Buffer.from([3]), // IdlInstruction::SetBuffer
  ]);
  const idlSetBufferInstructionCtorFields = {
    keys: idlSetBufferAccounts,
    programId: programId,
    data: idlSetBufferInstructionData,
  };
  const idlSetBufferInstruction = new TransactionInstruction(idlSetBufferInstructionCtorFields);

  const idlCloseAccounts: AccountMeta[] = [
    { pubkey: idlBuffer, isSigner: false, isWritable: true },
    { pubkey: multisig, isSigner: true, isWritable: false },
    { pubkey: closeRecipient, isSigner: false, isWritable: true },
  ];
  const idlCloseData = Buffer.concat([
    Buffer.from(sha256("anchor:idl")).slice(0, 8).reverse(),
    Buffer.from([5]), // IdlInstruction::Close
  ]);
  const idlCloseCtorFields = {
    keys: idlCloseAccounts,
    programId: programId,
    data: idlCloseData,
  };
  const idlCloseInstruction = new TransactionInstruction(idlCloseCtorFields);

  const multisigTransaction = new Transaction().add(idlSetBufferInstruction).add(idlCloseInstruction);
  multisigTransaction.recentBlockhash = "11111111111111111111111111111111"; // Placeholder blockhash
  multisigTransaction.feePayer = programId; // Placeholder fee payer as we are not signing the transaction
  const serializedMultisigTransaction = multisigTransaction.serializeMessage();

  console.log("IDL upgrade transaction, import it into the multisig:");
  console.log(bs58.encode(serializedMultisigTransaction));
}

// Run the squadsIdlUpgrade function
squadsIdlUpgrade();
