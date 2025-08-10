// This script is used to initiate a Solana deposit. useful in testing.

import { config } from "dotenv";
config();

import * as anchor from "@coral-xyz/anchor";
import { AnchorProvider, BN } from "@coral-xyz/anchor";
import {
  ASSOCIATED_TOKEN_PROGRAM_ID,
  TOKEN_PROGRAM_ID,
  createApproveCheckedInstruction,
  getAssociatedTokenAddressSync,
  getOrCreateAssociatedTokenAccount,
  getMint,
} from "@solana/spl-token";
import {
  PublicKey,
  SystemProgram,
  Transaction,
  TransactionInstruction,
  sendAndConfirmTransaction,
} from "@solana/web3.js";
import yargs from "yargs";
import { hideBin } from "yargs/helpers";
import {
  getDepositPda,
  getDepositSeedHash,
  getSpokePoolProgram,
  intToU8Array32,
  u8Array32ToInt,
  evmAddressToPublicKey,
} from "../../src/svm/web3-v1";
import { confirmTransaction } from "@solana-developers/helpers";

// anchor run --provider.cluster "https://solana-mainnet.g.alchemy.com/v2/TqEFuc6mBICfXwjc0THSmWe5NTwsfaNu" --provider.wallet dev-wallet.json simpleDeposit -- \
// --seed 1 \
// --recipient 6cTBgFKHYYW3iMTkuYemrhkScgXrD1RVFVvop23gHHEv \
// --inputToken EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v \
// --outputToken 5j5f8ph5oNpb7H9gnEedSfu5hPLZtdsCFnK6w6v13mqj \
// --inputAmount 1 \
// --outputAmount 0 \
// --destinationChainId 1 \
// --integratorId 1

// Set up the provider
console.log("ANCHOR_PROVIDER_URL", process.env.ANCHOR_PROVIDER_URL);
const provider = AnchorProvider.env();
// console.log("provider", provider);
anchor.setProvider(provider);
const program = getSpokePoolProgram(provider);
const programId = program.programId;
console.log("SVM-Spoke Program ID:", programId.toString());

console.log("process.argv", process.argv);
// Parse arguments
const argv = yargs(hideBin(process.argv))
  .option("seed", { type: "string", demandOption: true, describe: "Seed for the state account PDA" })
  .option("recipient", { type: "string", demandOption: true, describe: "Recipient public key" })
  .option("inputToken", { type: "string", demandOption: true, describe: "Input token public key" })
  .option("outputToken", { type: "string", demandOption: true, describe: "Output token public key" })
  .option("inputAmount", { type: "number", demandOption: true, describe: "Input amount" })
  .option("outputAmount", { type: "string", demandOption: true, describe: "Output amount" })
  .option("destinationChainId", { type: "string", demandOption: true, describe: "Destination chain ID" })
  .option("integratorId", { type: "string", demandOption: false, describe: "integrator ID" })
  .option("message", { type: "string", demandOption: false, describe: "message" }).argv;

async function deposit(): Promise<void> {
  const resolvedArgv = await argv;
  const seed = new BN(resolvedArgv.seed);
  const inputToken = new PublicKey(resolvedArgv.inputToken);
  const inputAmount = new BN(resolvedArgv.inputAmount);
  const outputAmount = intToU8Array32(new BN(resolvedArgv.outputAmount));
  const destinationChainId = new BN(resolvedArgv.destinationChainId);
  const exclusiveRelayer = PublicKey.default;
  const quoteTimestamp = Math.floor(Date.now() / 1000) - 10;
  const fillDeadline = quoteTimestamp + 3600; // 1 hour from now
  const exclusivityDeadline = 0;
  const message = Buffer.from(resolvedArgv.message?.replace("0x", "") || "", "hex");
  // const message = Buffer.from([]); // Convert to Buffer
  console.log("message", message.byteLength);
  console.log("integratorId", resolvedArgv.integratorId);
  const integratorId = resolvedArgv.integratorId || "";
  // Define the state account PDA
  const [statePda, _] = PublicKey.findProgramAddressSync(
    [Buffer.from("state"), seed.toArrayLike(Buffer, "le", 8)],
    programId
  );

  let recipient: PublicKey;
  if (resolvedArgv.recipient.toString().startsWith("0x")) {
    recipient = evmAddressToPublicKey(resolvedArgv.recipient.toString());
    console.log("recipientPublicKey", recipient);
  } else {
    recipient = new PublicKey(resolvedArgv.recipient);
  }

  let outputToken: PublicKey;
  if (resolvedArgv.outputToken.toString().startsWith("0x")) {
    outputToken = evmAddressToPublicKey(resolvedArgv.outputToken.toString());
    console.log("outputTokenPublicKey", outputToken);
  } else {
    outputToken = new PublicKey(resolvedArgv.outputToken);
  }

  // Define the signer (replace with your actual signer)
  const signer = (provider.wallet as anchor.Wallet).payer;

  // Find ATA for the input token to be stored by state (vault). This should have been created before the deposit is attempted.

  // connection, payer, mint, relayerA.publicKey
  // const vault = (await getOrCreateAssociatedTokenAccount(provider.connection, signer, inputToken, statePda, true))
  //   .address;
  const vault = getAssociatedTokenAddressSync(
    inputToken,
    statePda,
    true,
    TOKEN_PROGRAM_ID,
    ASSOCIATED_TOKEN_PROGRAM_ID
  );
  console.log("vault", vault);

  console.log("Depositing...");
  console.table([
    { property: "seed", value: seed.toString() },
    { property: "recipient", value: recipient.toString() },
    { property: "inputToken", value: inputToken.toString() },
    { property: "outputToken", value: outputToken.toString() },
    { property: "inputAmount", value: inputAmount.toString() },
    { property: "outputAmount", value: u8Array32ToInt(outputAmount).toString() },
    { property: "destinationChainId", value: destinationChainId.toString() },
    { property: "quoteTimestamp", value: quoteTimestamp.toString() },
    { property: "fillDeadline", value: fillDeadline.toString() },
    { property: "exclusivityDeadline", value: exclusivityDeadline.toString() },
    { property: "message", value: message.toString("hex") },
    { property: "integratorId", value: integratorId },
    { property: "programId", value: programId.toString() },
    { property: "providerPublicKey", value: provider.wallet.publicKey.toString() },
    { property: "statePda", value: statePda.toString() },
    { property: "vault", value: vault.toString() },
  ]);

  const userTokenAccount = getAssociatedTokenAddressSync(inputToken, signer.publicKey);

  console.log("userTokenAccount", userTokenAccount);

  const tokenDecimals = (await getMint(provider.connection, inputToken, undefined, TOKEN_PROGRAM_ID)).decimals;

  const depositData: Parameters<typeof getDepositSeedHash>[0] = {
    depositor: signer.publicKey,
    recipient,
    inputToken,
    outputToken,
    inputAmount,
    outputAmount,
    destinationChainId,
    exclusiveRelayer,
    quoteTimestamp: new BN(quoteTimestamp),
    fillDeadline: new BN(fillDeadline),
    exclusivityParameter: new BN(exclusivityDeadline),
    message,
  };
  const delegatePda = getDepositPda(depositData, program.programId);
  console.log("delegatePda", delegatePda);

  // Delegate state PDA to pull depositor tokens.
  const approveIx = await createApproveCheckedInstruction(
    userTokenAccount,
    inputToken,
    delegatePda,
    signer.publicKey,
    BigInt(inputAmount.toString()),
    tokenDecimals,
    undefined,
    TOKEN_PROGRAM_ID
  );

  const depositAccounts = {
    state: statePda,
    delegate: delegatePda,
    signer: signer.publicKey,
    depositorTokenAccount: userTokenAccount,
    vault: vault,
    mint: inputToken,
    tokenProgram: TOKEN_PROGRAM_ID,
    associatedTokenProgram: ASSOCIATED_TOKEN_PROGRAM_ID,
    systemProgram: SystemProgram.programId,
    program: programId,
  };

  console.log("outputAmount", outputAmount);
  // const depositIx = await program.methods
  //   .deposit(
  //     signer.publicKey,
  //     recipient,
  //     inputToken,
  //     outputToken,
  //     inputAmount,
  //     outputAmount,
  //     destinationChainId,
  //     exclusiveRelayer,
  //     quoteTimestamp,
  //     fillDeadline,
  //     exclusivityDeadline,
  //     message
  //   )
  //   .accounts(depositAccounts)
  //   .instruction();
  // // Create a custom instruction with arbitrary data

  // const depositTx = new Transaction().add(approveIx, depositIx);

  // if (integratorId !== "") {
  //   const MemoIx = new TransactionInstruction({
  //     keys: [{ pubkey: signer.publicKey, isSigner: true, isWritable: true }],
  //     data: Buffer.from(integratorId, "utf-8"),
  //     programId: new PublicKey("MemoSq4gqABAXKb96qnH8TysNcWxMyWCqXgDLGmfcHr"), // Memo program ID
  //   });
  //   depositTx.add(MemoIx);
  // }

  // const tx = await sendAndConfirmTransaction(provider.connection, depositTx, [signer]);
  // await confirmTransaction(provider.connection, tx, "confirmed");
  // console.log("Transaction signature:", tx);
}

// Run the deposit function
deposit();
