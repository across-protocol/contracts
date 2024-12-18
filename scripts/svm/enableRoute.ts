// This script is used by a chain admin to enable or disable a route for a token on the Solana Spoke Pool.

import * as anchor from "@coral-xyz/anchor";
import { BN, Program, AnchorProvider } from "@coral-xyz/anchor";
import { PublicKey, SystemProgram } from "@solana/web3.js";
import { ASSOCIATED_TOKEN_PROGRAM_ID, TOKEN_PROGRAM_ID, getAssociatedTokenAddressSync } from "@solana/spl-token";
import yargs from "yargs";
import { hideBin } from "yargs/helpers";
import { SvmSpokeAnchor, SvmSpokeIdl } from "../../src/svm/assets";

// Set up the provider
const provider = AnchorProvider.env();
anchor.setProvider(provider);
const program = new Program<SvmSpokeAnchor>(SvmSpokeIdl, provider);
const programId = program.programId;
console.log("SVM-Spoke Program ID:", programId.toString());

// Parse arguments
const argv = yargs(hideBin(process.argv))
  .option("seed", { type: "string", demandOption: true, describe: "Seed for the state account PDA" })
  .option("originToken", { type: "string", demandOption: true, describe: "Origin token public key" })
  .option("chainId", { type: "string", demandOption: true, describe: "Chain ID" })
  .option("enabled", { type: "boolean", demandOption: true, describe: "Enable or disable the route" }).argv;

async function enableRoute(): Promise<void> {
  const resolvedArgv = await argv;
  const seed = new BN(resolvedArgv.seed);
  const originToken = new PublicKey(resolvedArgv.originToken);
  const chainId = new BN(resolvedArgv.chainId);
  const enabled = resolvedArgv.enabled;

  // Define the state account PDA
  const [statePda, _] = PublicKey.findProgramAddressSync(
    [Buffer.from("state"), seed.toArrayLike(Buffer, "le", 8)],
    programId
  );

  // Define the route account PDA
  const [routePda] = PublicKey.findProgramAddressSync(
    [
      Buffer.from("route"),
      originToken.toBytes(),
      seed.toArrayLike(Buffer, "le", 8),
      chainId.toArrayLike(Buffer, "le", 8),
    ],
    programId
  );

  // Define the signer (replace with your actual signer)
  const signer = provider.wallet.publicKey;

  console.log("Enabling route...");
  console.table([
    { Property: "seed", Value: seed.toString() },
    { Property: "originToken", Value: originToken.toString() },
    { Property: "chainId", Value: chainId.toString() },
    { Property: "enabled", Value: enabled },
    { Property: "programId", Value: programId.toString() },
    { Property: "providerPublicKey", Value: provider.wallet.publicKey.toString() },
    { Property: "statePda", Value: statePda.toString() },
    { Property: "routePda", Value: routePda.toString() },
  ]);

  // Create ATA for the origin token to be stored by state (vault).
  const vault = getAssociatedTokenAddressSync(
    originToken,
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
      originTokenMint: originToken,
      tokenProgram: TOKEN_PROGRAM_ID,
      associatedTokenProgram: ASSOCIATED_TOKEN_PROGRAM_ID,
      systemProgram: SystemProgram.programId,
    })
    .rpc();

  console.log("Transaction signature:", tx);
}

// Run the enableRoute function
enableRoute();
