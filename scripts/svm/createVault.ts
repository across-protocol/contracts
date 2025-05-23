// This script can be used by a anyone to create a vault for a token on the Solana Spoke Pool. Note that this is a
// permissionless operation, only requiring the caller to spend rent-exempt deposit to create the vault account that is
// not recoverable. Similar to other chains, this enables one to deposit and fill non-whitelisted tokens.

import * as anchor from "@coral-xyz/anchor";
import { AnchorProvider, BN } from "@coral-xyz/anchor";
import { ASSOCIATED_TOKEN_PROGRAM_ID, TOKEN_PROGRAM_ID, getOrCreateAssociatedTokenAccount } from "@solana/spl-token";
import { PublicKey } from "@solana/web3.js";
import yargs from "yargs";
import { hideBin } from "yargs/helpers";
import { getSpokePoolProgram, SOLANA_SPOKE_STATE_SEED } from "../../src/svm/web3-v1";

// Set up the provider
const provider = AnchorProvider.env();
anchor.setProvider(provider);
const payer = (anchor.AnchorProvider.env().wallet as anchor.Wallet).payer;
const program = getSpokePoolProgram(provider);
const programId = program.programId;
console.log("SVM-Spoke Program ID:", programId.toString());

// Parse arguments
const argv = yargs(hideBin(process.argv))
  .option("seed", { type: "string", demandOption: false, describe: "Seed for the state account PDA" })
  .option("originToken", { type: "string", demandOption: true, describe: "Origin token public key" }).argv;

async function createVault(): Promise<void> {
  const resolvedArgv = await argv;
  const seed = resolvedArgv.seed ? new BN(resolvedArgv.seed) : SOLANA_SPOKE_STATE_SEED;
  const originToken = new PublicKey(resolvedArgv.originToken);

  // Define the state account PDA
  const [statePda, _] = PublicKey.findProgramAddressSync(
    [Buffer.from("state"), seed.toArrayLike(Buffer, "le", 8)],
    programId
  );

  // Define the signer (replace with your actual signer)
  const signer = provider.wallet.publicKey;

  console.log("Creating vault...");
  console.table([
    { Property: "seed", Value: seed.toString() },
    { Property: "originToken", Value: originToken.toString() },
    { Property: "programId", Value: programId.toString() },
    { Property: "providerPublicKey", Value: provider.wallet.publicKey.toString() },
    { Property: "statePda", Value: statePda.toString() },
  ]);

  // Create ATA for the origin token to be stored by state (vault).
  const vault = await getOrCreateAssociatedTokenAccount(
    provider.connection,
    payer,
    originToken,
    statePda,
    true,
    "confirmed",
    {
      commitment: "confirmed",
    },
    TOKEN_PROGRAM_ID,
    ASSOCIATED_TOKEN_PROGRAM_ID
  );

  console.log("Created vault:", vault.address.toString());
}

// Run the createVault function
createVault();
