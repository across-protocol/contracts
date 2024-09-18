import * as anchor from "@coral-xyz/anchor";
import { BN, Program, AnchorProvider } from "@coral-xyz/anchor";
import { PublicKey } from "@solana/web3.js";
import {
  ASSOCIATED_TOKEN_PROGRAM_ID,
  TOKEN_PROGRAM_ID,
  getAssociatedTokenAddressSync,
  getAccount,
} from "@solana/spl-token";
import { SvmSpoke } from "../../target/types/svm_spoke";
import yargs from "yargs";
import { hideBin } from "yargs/helpers";

// Set up the provider
const provider = AnchorProvider.env();
anchor.setProvider(provider);
const idl = require("../target/idl/svm_spoke.json");
const program = new Program<SvmSpoke>(idl, provider);
const programId = program.programId;

// Parse arguments
const argv = yargs(hideBin(process.argv))
  .option("originToken", { type: "string", demandOption: true, describe: "Origin token public key" })
  .option("chainId", { type: "string", demandOption: true, describe: "Chain ID" }).argv;

const originToken = Array.from(new PublicKey(argv.originToken).toBytes()); // Convert to number[]
const chainId = new BN(argv.chainId);

// Define the route account PDA
const [routePda] = PublicKey.findProgramAddressSync(
  [Buffer.from("route"), Buffer.from(originToken), chainId.toArrayLike(Buffer, "le", 8)],
  programId
);

// Define the state account PDA (assuming the seed is known or can be derived)
const seed = new BN(0); // Replace with actual seed if known
const [statePda] = PublicKey.findProgramAddressSync(
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

async function queryRoute(): Promise<void> {
  console.log("Querying route...");
  console.table([
    { Property: "originToken", Value: new PublicKey(originToken).toString() },
    { Property: "chainId", Value: chainId.toString() },
    { Property: "programId", Value: programId.toString() },
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
  } catch (error) {
    if (error.message.includes("Account does not exist or has no data")) {
      console.log("No route has been created for the given origin token and chain ID.");
    } else {
      console.error("An error occurred while fetching the route:", error);
    }
  }
}

// Run the queryRoute function
queryRoute();
