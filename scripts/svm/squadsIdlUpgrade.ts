// Legacy Anchor 0.31 deployments only. Anchor 1.1.2 uses Program Metadata, not this dispatcher.
// This script prepares transaction for finalizing IDL upgrade and prints out Base58 encoded transaction that can be
// imported in the Squads transaction builder. This requires one first to have written the upgraded IDL to the buffer
// account (anchor idl write-buffer) and set its authority to the Squads multisig (anchor idl set-authority).
// Use --closeIdl instead of --idlBuffer to close the canonical legacy IDL before upgrading the program binary.

import { PublicKey } from "@solana/web3.js";
import yargs from "yargs";
import { hideBin } from "yargs/helpers";
import { AccountMeta, Transaction, TransactionInstruction } from "@solana/web3.js";
import { sha256 } from "@noble/hashes/sha2";
import bs58 from "bs58";

// Parse arguments
const argv = yargs(hideBin(process.argv))
  .option("programId", { type: "string", demandOption: true, describe: "Program owning the legacy IDL" })
  .option("idlBuffer", { type: "string", describe: "Buffer account where IDL has been written" })
  .option("closeIdl", {
    type: "boolean",
    default: false,
    describe: "Close the canonical legacy IDL without updating it",
  })
  .option("closeRecipient", {
    type: "string",
    demandOption: true,
    describe: "Account to receive the closed account's SOL",
  })
  .option("multisig", { type: "string", demandOption: true, describe: "Squads vault holding legacy IDL authority" })
  .check((args) => {
    if (args.closeIdl === Boolean(args.idlBuffer)) throw new Error("Supply either --idlBuffer or --closeIdl, not both");
    return true;
  }).argv;

async function squadsIdlUpgrade() {
  const resolvedArgv = await argv;
  const programId = new PublicKey(resolvedArgv.programId);
  const idlBuffer = resolvedArgv.idlBuffer ? new PublicKey(resolvedArgv.idlBuffer) : undefined;
  const multisig = new PublicKey(resolvedArgv.multisig);
  const closeRecipient = new PublicKey(resolvedArgv.closeRecipient);

  // Get the deterministic IDL address for the program:
  const base = PublicKey.findProgramAddressSync([], programId)[0];
  const idlAddress = await PublicKey.createWithSeed(base, "anchor:idl", programId);

  console.log(
    resolvedArgv.closeIdl ? "Creating legacy IDL close transaction..." : "Creating IDL upgrade transaction..."
  );
  console.table([
    { Property: "programId", Value: programId.toString() },
    { Property: "idlBuffer", Value: idlBuffer?.toString() ?? "none (close canonical legacy IDL)" },
    { Property: "idlAddress", Value: idlAddress.toString() },
    { Property: "multisig", Value: multisig.toString() },
    { Property: "closeRecipient", Value: closeRecipient.toString() },
  ]);

  const multisigTransaction = new Transaction();
  if (idlBuffer) {
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
    multisigTransaction.add(idlSetBufferInstruction);
  }

  const idlCloseAccounts: AccountMeta[] = [
    { pubkey: idlBuffer ?? idlAddress, isSigner: false, isWritable: true },
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

  multisigTransaction.add(idlCloseInstruction);
  multisigTransaction.recentBlockhash = "11111111111111111111111111111111"; // Placeholder blockhash
  multisigTransaction.feePayer = programId; // Placeholder fee payer as we are not signing the transaction
  const serializedMultisigTransaction = multisigTransaction.serializeMessage();

  console.log("Legacy IDL transaction, import it into the multisig:");
  console.log(bs58.encode(serializedMultisigTransaction));
}

// Run the squadsIdlUpgrade function
squadsIdlUpgrade();
