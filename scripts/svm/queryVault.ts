// This script fetches vault information for a given spoke pool and originToken.

import * as anchor from "@coral-xyz/anchor";
import { AnchorProvider, BN } from "@coral-xyz/anchor";
import {
  ASSOCIATED_TOKEN_PROGRAM_ID,
  TOKEN_PROGRAM_ID,
  getAccount,
  getAssociatedTokenAddressSync,
} from "@solana/spl-token";
import { PublicKey } from "@solana/web3.js";
import yargs from "yargs";
import { hideBin } from "yargs/helpers";
import { getSpokePoolProgram } from "../../src/svm/web3-v1";

// Set up the provider
const provider = AnchorProvider.env();
anchor.setProvider(provider);
const program = getSpokePoolProgram(provider);
const programId = program.programId;
console.log("SVM-Spoke Program ID:", programId.toString());

// Parse arguments
const argv = yargs(hideBin(process.argv))
  .option("seed", { type: "string", demandOption: true, describe: "Seed for the state account PDA" })
  .option("originToken", { type: "string", demandOption: true, describe: "Origin token public key" }).argv;

async function queryVault(): Promise<void> {
  const resolvedArgv = await argv;
  const seed = new BN(resolvedArgv.seed);
  const originToken = Array.from(new PublicKey(resolvedArgv.originToken).toBytes());

  // Define the state account PDA
  const [statePda, _] = PublicKey.findProgramAddressSync(
    [Buffer.from("state"), seed.toArrayLike(Buffer, "le", 8)],
    programId
  );

  // Compute the vault address
  const vault = getAssociatedTokenAddressSync(
    new PublicKey(originToken),
    statePda,
    true,
    TOKEN_PROGRAM_ID,
    ASSOCIATED_TOKEN_PROGRAM_ID
  );

  console.log("Querying vault...");
  console.table([
    { Property: "seed", Value: seed.toString() },
    { Property: "originToken", Value: new PublicKey(originToken).toString() },
    { Property: "programId", Value: programId.toString() },
    { Property: "statePda", Value: statePda.toString() },
    { Property: "vault", Value: vault.toString() },
  ]);

  try {
    const vaultAccount = await getAccount(provider.connection, vault);

    console.log("Vault fetched successfully:");
    console.table([{ Property: "vaultBalance", Value: vaultAccount.amount.toString() }]);
  } catch (error: any) {
    if (error.message.includes("Account does not exist or has no data")) {
      console.log("No vault has been created for the given origin token.");
    } else {
      console.error("An error occurred while fetching the vault:", error);
    }
  }
}

// Run the queryVault function
queryVault();
