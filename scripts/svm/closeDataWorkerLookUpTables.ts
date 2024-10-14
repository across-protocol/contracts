import * as anchor from "@coral-xyz/anchor";
import { AddressLookupTableProgram } from "@solana/web3.js";

// Set up the provider
const provider = anchor.AnchorProvider.env();
anchor.setProvider(provider);
const connection = provider.connection;
const payer = provider.wallet.publicKey;

async function closeDataWorkerLookUpTables(): Promise<void> {
  console.log("Starting process to close dataworker lookup tables...");
  console.log(`Signer: ${payer.toBase58()}`);

  try {
    const accounts = await connection.getProgramAccounts(AddressLookupTableProgram.programId, {
      filters: [{ memcmp: { offset: 22, bytes: payer.toBase58() } }],
    });

    console.log(`Found ${accounts.length} lookup tables.`);

    for (const account of accounts) {
      const lookupTableAddress = account.pubkey;
      console.log(`\nProcessing lookup table: ${lookupTableAddress.toBase58()}`);

      try {
        // Attempt to deactivate the lookup table
        const deactivateInstruction = AddressLookupTableProgram.deactivateLookupTable({
          lookupTable: lookupTableAddress,
          authority: payer,
        });

        const deactivateTransaction = new anchor.web3.Transaction().add(deactivateInstruction);
        const deactivateSignature = await provider.sendAndConfirm(deactivateTransaction, [
          (anchor.AnchorProvider.env().wallet as anchor.Wallet).payer,
        ]);
        console.log(`Deactivated: ${lookupTableAddress.toBase58()} | Tx Hash: ${deactivateSignature}`);
      } catch {
        console.error(`Pending deactivation: ${lookupTableAddress.toBase58()}`);
      }

      try {
        // Attempt to close the lookup table
        const closeInstruction = AddressLookupTableProgram.closeLookupTable({
          lookupTable: lookupTableAddress,
          authority: payer,
          recipient: payer,
        });

        const closeTransaction = new anchor.web3.Transaction().add(closeInstruction);
        const closeSignature = await provider.sendAndConfirm(closeTransaction, [
          (anchor.AnchorProvider.env().wallet as anchor.Wallet).payer,
        ]);
        console.log(`Closed: ${lookupTableAddress.toBase58()} | Tx Hash: ${closeSignature}`);
      } catch {
        console.error(`Pending closure: ${lookupTableAddress.toBase58()}`);
      }
    }
  } catch (error) {
    console.error("Error fetching lookup tables:", error);
  }
}

// Run the closeDataWorkerLookUpTables function
closeDataWorkerLookUpTables();
