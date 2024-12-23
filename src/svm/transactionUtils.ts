import { web3 } from "@coral-xyz/anchor";
import {
  AddressLookupTableProgram,
  Connection,
  Keypair,
  TransactionInstruction,
  TransactionMessage,
  VersionedTransaction,
  AddressLookupTableAccount,
  Commitment,
  Transaction,
  ComputeBudgetProgram,
} from "@solana/web3.js";

/**
 * Confirms transaction using the latest block, defaulting to confirmed commitment.
 */
export async function confirmTransaction(connection: Connection, txSignature: string, commitment?: Commitment) {
  const block = await connection.getLatestBlockhash();
  await connection.confirmTransaction(
    { signature: txSignature, blockhash: block.blockhash, lastValidBlockHeight: block.lastValidBlockHeight },
    commitment || "confirmed"
  );
}

/**
 * Sends a transaction using an Address Lookup Table for large numbers of accounts.
 */
export async function sendTransactionWithLookupTable(
  connection: Connection,
  instructions: TransactionInstruction[],
  sender: Keypair,
  lookupTables?: AddressLookupTableAccount[]
): Promise<string> {
  // If lookup tables were provided, just send transaction using them.
  if (lookupTables) {
    const versionedTx = new VersionedTransaction(
      new TransactionMessage({
        payerKey: sender.publicKey,
        recentBlockhash: (await connection.getLatestBlockhash()).blockhash,
        instructions,
      }).compileToV0Message(lookupTables)
    );

    // Sign and submit the versioned transaction.
    versionedTx.sign([sender]);
    const txSignature = await connection.sendTransaction(versionedTx);

    // Confirm the versioned transaction
    await confirmTransaction(connection, txSignature);

    return txSignature;
  }

  // Maximum number of accounts that can be added to Address Lookup Table (ALT) in a single transaction.
  const maxExtendedAccounts = 30;

  // Consolidate addresses from all instructions into a single array for the ALT.
  const lookupAddresses = Array.from(
    new Set(
      instructions.flatMap((instruction) => [
        instruction.programId,
        ...instruction.keys.map((accountMeta) => accountMeta.pubkey),
      ])
    )
  );

  // Create instructions for creating and extending the ALT.
  const [lookupTableInstruction, lookupTableAddress] = await AddressLookupTableProgram.createLookupTable({
    authority: sender.publicKey,
    payer: sender.publicKey,
    recentSlot: await connection.getSlot(),
  });

  // Submit the ALT creation transaction
  await web3.sendAndConfirmTransaction(connection, new web3.Transaction().add(lookupTableInstruction), [sender], {
    commitment: "confirmed",
    skipPreflight: true,
  });

  // Extend the ALT with all accounts making sure not to exceed the maximum number of accounts per transaction.
  for (let i = 0; i < lookupAddresses.length; i += maxExtendedAccounts) {
    const extendInstruction = AddressLookupTableProgram.extendLookupTable({
      lookupTable: lookupTableAddress,
      authority: sender.publicKey,
      payer: sender.publicKey,
      addresses: lookupAddresses.slice(i, i + maxExtendedAccounts),
    });

    await web3.sendAndConfirmTransaction(connection, new web3.Transaction().add(extendInstruction), [sender], {
      commitment: "confirmed",
      skipPreflight: true,
    });
  }

  // Wait for slot to advance. LUTs only active after slot advance.
  const initialSlot = await connection.getSlot();
  while ((await connection.getSlot()) === initialSlot) {
    await new Promise((resolve) => setTimeout(resolve, 50));
  }

  // Fetch the AddressLookupTableAccount
  const lookupTableAccount = (await connection.getAddressLookupTable(lookupTableAddress)).value;
  if (lookupTableAccount === null) throw new Error("AddressLookupTableAccount not fetched");

  // Create the versioned transaction
  const versionedTx = new VersionedTransaction(
    new TransactionMessage({
      payerKey: sender.publicKey,
      recentBlockhash: (await connection.getLatestBlockhash()).blockhash,
      instructions,
    }).compileToV0Message([lookupTableAccount])
  );

  // Sign and submit the versioned transaction.
  versionedTx.sign([sender]);
  const txSignature = await connection.sendTransaction(versionedTx);

  // Confirm the versioned transaction
  await confirmTransaction(connection, txSignature);

  return txSignature;
}

/*
 * Creates a transaction with optional ComputeBudget instructions.
 */
export function createTransactionWithComputeBudget(
  instructions: TransactionInstruction[],
  priorityFeePrice?: number | bigint,
  computeUnitLimit?: number
) {
  return new Transaction().add(...prependComputeBudget(instructions, priorityFeePrice, computeUnitLimit));
}

/*
 * Prepends optional ComputeBudget instructions to the transaction instructions.
 */
export function prependComputeBudget(
  instructions: TransactionInstruction[],
  priorityFeePrice?: number | bigint,
  computeUnitLimit?: number
) {
  if (computeUnitLimit) instructions.unshift(ComputeBudgetProgram.setComputeUnitLimit({ units: computeUnitLimit }));
  if (priorityFeePrice)
    instructions.unshift(ComputeBudgetProgram.setComputeUnitPrice({ microLamports: priorityFeePrice }));
  return instructions;
}
