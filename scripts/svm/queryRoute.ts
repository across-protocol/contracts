// This script fetches route information for a given spoke pool, originToken and chainId.

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
import { getSpokePoolProgram } from "../../src/svm";

// Set up the provider
const provider = AnchorProvider.env();
anchor.setProvider(provider);
const program = getSpokePoolProgram(provider);
const programId = program.programId;
console.log("SVM-Spoke Program ID:", programId.toString());

// Parse arguments
const argv = yargs(hideBin(process.argv))
  .option("seed", { type: "string", demandOption: true, describe: "Seed for the state account PDA" })
  .option("originToken", { type: "string", demandOption: true, describe: "Origin token public key" })
  .option("chainId", { type: "string", demandOption: true, describe: "Chain ID" }).argv;

async function queryRoute(): Promise<void> {
  const resolvedArgv = await argv;
  const seed = new BN(resolvedArgv.seed);
  const originToken = Array.from(new PublicKey(resolvedArgv.originToken).toBytes());
  const chainId = new BN(resolvedArgv.chainId);

  // Define the state account PDA
  const [statePda, _] = PublicKey.findProgramAddressSync(
    [Buffer.from("state"), seed.toArrayLike(Buffer, "le", 8)],
    programId
  );

  // Define the route account PDA
  const [routePda] = PublicKey.findProgramAddressSync(
    [
      Buffer.from("route"),
      Buffer.from(originToken),
      seed.toArrayLike(Buffer, "le", 8),
      chainId.toArrayLike(Buffer, "le", 8),
    ],
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

  console.log("Querying route...");
  console.table([
    { Property: "seed", Value: seed.toString() },
    { Property: "originToken", Value: new PublicKey(originToken).toString() },
    { Property: "chainId", Value: chainId.toString() },
    { Property: "programId", Value: programId.toString() },
    { Property: "statePda", Value: statePda.toString() },
    { Property: "routePda", Value: routePda.toString() },
    { Property: "vault", Value: vault.toString() },
  ]);

  try {
    const route = await program.account.route.fetch(routePda);
    const vaultAccount = await getAccount(provider.connection, vault);

    console.log("Route fetched successfully:");
    console.table([
      { Property: "Enabled", Value: route.enabled },
      { Property: "vaultBalance", Value: vaultAccount.amount.toString() },
    ]);
  } catch (error: any) {
    if (error.message.includes("Account does not exist or has no data")) {
      console.log("No route has been created for the given origin token and chain ID.");
    } else {
      console.error("An error occurred while fetching the route:", error);
    }
  }
}

// Run the queryRoute function
queryRoute();
