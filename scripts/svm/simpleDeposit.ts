// This script is used to initiate a Solana deposit. useful in testing.

import * as anchor from "@coral-xyz/anchor";
import { AnchorProvider, BN } from "@coral-xyz/anchor";
import {
  ASSOCIATED_TOKEN_PROGRAM_ID,
  TOKEN_PROGRAM_ID,
  createApproveCheckedInstruction,
  getAssociatedTokenAddressSync,
  getMint,
} from "@solana/spl-token";
import { PublicKey, Transaction, sendAndConfirmTransaction } from "@solana/web3.js";
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
  .option("recipient", { type: "string", demandOption: true, describe: "Recipient public key" })
  .option("inputToken", { type: "string", demandOption: true, describe: "Input token public key" })
  .option("outputToken", { type: "string", demandOption: true, describe: "Output token public key" })
  .option("inputAmount", { type: "number", demandOption: true, describe: "Input amount" })
  .option("outputAmount", { type: "number", demandOption: true, describe: "Output amount" })
  .option("destinationChainId", { type: "string", demandOption: true, describe: "Destination chain ID" }).argv;

async function depositV3(): Promise<void> {
  const resolvedArgv = await argv;
  const seed = new BN(resolvedArgv.seed);
  const recipient = new PublicKey(resolvedArgv.recipient);
  const inputToken = new PublicKey(resolvedArgv.inputToken);
  const outputToken = new PublicKey(resolvedArgv.outputToken);
  const inputAmount = new BN(resolvedArgv.inputAmount);
  const outputAmount = new BN(resolvedArgv.outputAmount);
  const destinationChainId = new BN(resolvedArgv.destinationChainId);
  const exclusiveRelayer = PublicKey.default;
  const quoteTimestamp = Math.floor(Date.now() / 1000) - 1;
  const fillDeadline = quoteTimestamp + 3600; // 1 hour from now
  const exclusivityDeadline = 0;
  const message = Buffer.from([]); // Convert to Buffer

  // Define the state account PDA
  const [statePda, _] = PublicKey.findProgramAddressSync(
    [Buffer.from("state"), seed.toArrayLike(Buffer, "le", 8)],
    programId
  );

  // Define the route account PDA
  const [routePda] = PublicKey.findProgramAddressSync(
    [
      Buffer.from("route"),
      inputToken.toBytes(),
      seed.toArrayLike(Buffer, "le", 8),
      destinationChainId.toArrayLike(Buffer, "le", 8),
    ],
    programId
  );

  // Define the signer (replace with your actual signer)
  const signer = (provider.wallet as anchor.Wallet).payer;

  // Find ATA for the input token to be stored by state (vault). This was created when the route was enabled.
  const vault = getAssociatedTokenAddressSync(
    inputToken,
    statePda,
    true,
    TOKEN_PROGRAM_ID,
    ASSOCIATED_TOKEN_PROGRAM_ID
  );

  console.log("Depositing V3...");
  console.table([
    { property: "seed", value: seed.toString() },
    { property: "recipient", value: recipient.toString() },
    { property: "inputToken", value: inputToken.toString() },
    { property: "outputToken", value: outputToken.toString() },
    { property: "inputAmount", value: inputAmount.toString() },
    { property: "outputAmount", value: outputAmount.toString() },
    { property: "destinationChainId", value: destinationChainId.toString() },
    { property: "quoteTimestamp", value: quoteTimestamp.toString() },
    { property: "fillDeadline", value: fillDeadline.toString() },
    { property: "exclusivityDeadline", value: exclusivityDeadline.toString() },
    { property: "programId", value: programId.toString() },
    { property: "providerPublicKey", value: provider.wallet.publicKey.toString() },
    { property: "statePda", value: statePda.toString() },
    { property: "routePda", value: routePda.toString() },
    { property: "vault", value: vault.toString() },
  ]);

  const userTokenAccount = getAssociatedTokenAddressSync(inputToken, signer.publicKey);

  const tokenDecimals = (await getMint(provider.connection, inputToken, undefined, TOKEN_PROGRAM_ID)).decimals;

  // Delegate state PDA to pull depositor tokens.
  const approveIx = await createApproveCheckedInstruction(
    userTokenAccount,
    inputToken,
    statePda,
    signer.publicKey,
    BigInt(inputAmount.toString()),
    tokenDecimals,
    undefined,
    TOKEN_PROGRAM_ID
  );

  const depositIx = await (
    program.methods.depositV3(
      signer.publicKey,
      recipient,
      inputToken,
      outputToken,
      inputAmount,
      outputAmount,
      destinationChainId,
      exclusiveRelayer,
      quoteTimestamp,
      fillDeadline,
      exclusivityDeadline,
      message
    ) as any
  )
    .accounts({
      state: statePda,
      route: routePda,
      signer: signer.publicKey,
      userTokenAccount,
      vault: vault,
      tokenProgram: TOKEN_PROGRAM_ID,
      mint: inputToken,
    })
    .instruction();
  const depositTx = new Transaction().add(approveIx, depositIx);
  const tx = await sendAndConfirmTransaction(provider.connection, depositTx, [signer]);

  console.log("Transaction signature:", tx);
}

// Run the depositV3 function
depositV3();
