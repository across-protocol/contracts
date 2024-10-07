import * as anchor from "@coral-xyz/anchor";
import { BN, Program, AnchorProvider } from "@coral-xyz/anchor";
import { PublicKey, SystemProgram } from "@solana/web3.js";
import { ASSOCIATED_TOKEN_PROGRAM_ID, TOKEN_PROGRAM_ID, getAssociatedTokenAddressSync } from "@solana/spl-token";
import { SvmSpoke } from "../../target/types/svm_spoke";
import yargs from "yargs";
import { hideBin } from "yargs/helpers";

// Set up the provider
const provider = AnchorProvider.env();
anchor.setProvider(provider);
const idl = require("../../target/idl/svm_spoke.json");
const program = new Program<SvmSpoke>(idl, provider);
const programId = program.programId;

// Parse arguments
const argv = yargs(hideBin(process.argv))
  .option("seed", { type: "string", demandOption: true, describe: "Seed for the state account PDA" })
  .option("originToken", { type: "string", demandOption: true, describe: "Origin token public key" })
  .option("chainId", { type: "string", demandOption: true, describe: "Chain ID" })
  .option("enabled", { type: "boolean", demandOption: true, describe: "Enable or disable the route" }).argv;

async function enableRoute(): Promise<void> {
  const resolvedArgv = await argv;
  const seed = new BN(resolvedArgv.seed);
  const originToken = Array.from(new PublicKey(resolvedArgv.originToken).toBytes()); // Convert to number[]
  const chainId = new BN(resolvedArgv.chainId);
  const enabled = resolvedArgv.enabled;

  // Define the state account PDA
  const [statePda, _] = PublicKey.findProgramAddressSync(
    [Buffer.from("state"), seed.toArrayLike(Buffer, "le", 8)],
    programId
  );

  // Define the route account PDA
  const [routePda] = PublicKey.findProgramAddressSync(
    [Buffer.from("route"), Buffer.from(originToken), statePda.toBytes(), chainId.toArrayLike(Buffer, "le", 8)],
    programId
  );

  // Define the signer (replace with your actual signer)
  const signer = provider.wallet.publicKey;

  console.log("Enabling route...");
  console.table([
    { Property: "seed", Value: seed.toString() },
    { Property: "originToken", Value: new PublicKey(originToken).toString() },
    { Property: "chainId", Value: chainId.toString() },
    { Property: "enabled", Value: enabled },
    { Property: "programId", Value: programId.toString() },
    { Property: "providerPublicKey", Value: provider.wallet.publicKey.toString() },
    { Property: "statePda", Value: statePda.toString() },
    { Property: "routePda", Value: routePda.toString() },
  ]);

  // Create ATA for the origin token to be stored by state (vault).
  const vault = getAssociatedTokenAddressSync(
    new PublicKey(originToken),
    statePda,
    true,
    TOKEN_PROGRAM_ID,
    ASSOCIATED_TOKEN_PROGRAM_ID
  );

  const tx = await (program.methods.setEnableRoute(originToken, chainId, enabled) as any)
    .accounts({
      signer: signer,
      payer: signer,
      state: statePda,
      route: routePda,
      vault: vault,
      originTokenMint: new PublicKey(originToken),
      tokenProgram: TOKEN_PROGRAM_ID,
      associatedTokenProgram: ASSOCIATED_TOKEN_PROGRAM_ID,
      systemProgram: SystemProgram.programId,
    })
    .rpc();

  console.log("Transaction signature:", tx);
}

// Run the enableRoute function
enableRoute();
