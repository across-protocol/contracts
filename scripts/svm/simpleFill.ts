// This script implements a simple relayer fill against known deposit props. Note that if the deposit data is done wrong
// this script can easily create invalid fills.

import * as anchor from "@coral-xyz/anchor";
import { BN, Program, AnchorProvider } from "@coral-xyz/anchor";
import { PublicKey, SystemProgram, Transaction, sendAndConfirmTransaction } from "@solana/web3.js";
import {
  ASSOCIATED_TOKEN_PROGRAM_ID,
  TOKEN_PROGRAM_ID,
  createApproveCheckedInstruction,
  getAssociatedTokenAddressSync,
  getMint,
  getOrCreateAssociatedTokenAccount,
} from "@solana/spl-token";
import { SvmSpoke } from "../../target/types/svm_spoke";
import yargs from "yargs";
import { hideBin } from "yargs/helpers";
import { calculateRelayHashUint8Array } from "../../src/SvmUtils";

// Set up the provider
const provider = AnchorProvider.env();
anchor.setProvider(provider);
const idl = require("../../target/idl/svm_spoke.json");
const program = new Program<SvmSpoke>(idl, provider);
const programId = program.programId;

// Parse arguments
const argv = yargs(hideBin(process.argv))
  .option("seed", { type: "string", demandOption: true, describe: "Seed for the state account PDA" })
  .option("depositor", { type: "string", demandOption: true, describe: "Depositor public key" })
  .option("recipient", { type: "string", demandOption: true, describe: "Recipient public key" })
  .option("exclusiveRelayer", { type: "string", demandOption: false, describe: "Exclusive relayer public key" })
  .option("inputToken", { type: "string", demandOption: true, describe: "Input token public key" })
  .option("outputToken", { type: "string", demandOption: true, describe: "Output token public key" })
  .option("inputAmount", { type: "number", demandOption: true, describe: "Input amount" })
  .option("outputAmount", { type: "number", demandOption: true, describe: "Output amount" })
  .option("originChainId", { type: "string", demandOption: true, describe: "Origin chain ID" })
  .option("depositId", { type: "array", demandOption: true, describe: "Deposit ID" })
  .option("fillDeadline", { type: "number", demandOption: false, describe: "Fill deadline" })
  .option("exclusivityDeadline", { type: "number", demandOption: false, describe: "Exclusivity deadline" }).argv;

async function fillV3Relay(): Promise<void> {
  vm;
  const resolvedArgv = await argv;
  const depositor = new PublicKey(resolvedArgv.depositor);
  const recipient = new PublicKey(resolvedArgv.recipient);
  const exclusiveRelayer = new PublicKey(resolvedArgv.exclusiveRelayer || "11111111111111111111111111111111");
  const inputToken = new PublicKey(resolvedArgv.inputToken);
  const outputToken = new PublicKey(resolvedArgv.outputToken);
  const inputAmount = new BN(resolvedArgv.inputAmount);
  const outputAmount = new BN(resolvedArgv.outputAmount);
  const originChainId = new BN(resolvedArgv.originChainId);
  const depositId = resolvedArgv.depositId;
  const fillDeadline = resolvedArgv.fillDeadline || Math.floor(Date.now() / 1000) + 60; // Current time + 1 minute
  const exclusivityDeadline = resolvedArgv.exclusivityDeadline || Math.floor(Date.now() / 1000) + 30; // Current time + 30 seconds
  const message = Buffer.from("");
  const seed = new BN(resolvedArgv.seed);

  const relayData = {
    depositor,
    recipient,
    exclusiveRelayer,
    inputToken,
    outputToken,
    inputAmount,
    outputAmount,
    originChainId,
    depositId: depositId.map((id) => Number(id)),
    fillDeadline,
    exclusivityDeadline,
    message,
  };

  // Define the signer (replace with your actual signer)
  const signer = (provider.wallet as anchor.Wallet).payer;

  console.log("Filling V3 Relay...");

  // Define the state account PDA
  const [statePda, _] = PublicKey.findProgramAddressSync(
    [Buffer.from("state"), seed.toArrayLike(Buffer, "le", 8)],
    programId
  );

  // Fetch the state from the on-chain program to get chainId
  const state = await program.account.state.fetch(statePda);
  const chainId = new BN(state.chainId);

  const relayHashUint8Array = calculateRelayHashUint8Array(relayData, chainId);

  // Define the fill status account PDA
  const [fillStatusPda] = PublicKey.findProgramAddressSync([Buffer.from("fills"), relayHashUint8Array], programId);

  // Create ATA for the relayer and recipient token accounts
  const relayerTokenAccount = getAssociatedTokenAddressSync(
    outputToken,
    signer.publicKey,
    true,
    TOKEN_PROGRAM_ID,
    ASSOCIATED_TOKEN_PROGRAM_ID
  );

  const recipientTokenAccount = (
    await getOrCreateAssociatedTokenAccount(
      provider.connection,
      signer,
      outputToken,
      recipient,
      true,
      undefined,
      undefined,
      TOKEN_PROGRAM_ID,
      ASSOCIATED_TOKEN_PROGRAM_ID
    )
  ).address;

  console.table([
    { property: "relayHash", value: Buffer.from(relayHashUint8Array).toString("hex") },
    { property: "chainId", value: chainId.toString() },
    { property: "programId", value: programId.toString() },
    { property: "providerPublicKey", value: provider.wallet.publicKey.toString() },
    { property: "statePda", value: statePda.toString() },
    { property: "fillStatusPda", value: fillStatusPda.toString() },
    { property: "relayerTokenAccount", value: relayerTokenAccount.toString() },
    { property: "recipientTokenAccount", value: recipientTokenAccount.toString() },
    { property: "seed", value: seed.toString() },
  ]);

  console.log("Relay Data:");
  console.table(
    Object.entries(relayData).map(([key, value]) => ({
      key,
      value: value.toString(),
    }))
  );

  const tokenDecimals = (await getMint(provider.connection, outputToken, undefined, TOKEN_PROGRAM_ID)).decimals;

  // Delegate state PDA to pull relayer tokens.
  const approveIx = await createApproveCheckedInstruction(
    relayerTokenAccount,
    outputToken,
    statePda,
    signer.publicKey,
    BigInt(relayData.outputAmount.toString()),
    tokenDecimals,
    undefined,
    TOKEN_PROGRAM_ID
  );

  const fillIx = await (
    program.methods.fillV3Relay(Array.from(relayHashUint8Array), relayData, chainId, signer.publicKey) as any
  )
    .accounts({
      state: statePda,
      signer: signer.publicKey,
      instructionParams: program.programId,
      mintAccount: outputToken,
      relayerTokenAccount: relayerTokenAccount,
      recipientTokenAccount: recipientTokenAccount,
      fillStatus: fillStatusPda,
      tokenProgram: TOKEN_PROGRAM_ID,
      associatedTokenProgram: ASSOCIATED_TOKEN_PROGRAM_ID,
      systemProgram: SystemProgram.programId,
      programId: programId,
    })
    .instruction();
  const fillTx = new Transaction().add(approveIx, fillIx);
  const tx = await sendAndConfirmTransaction(provider.connection, fillTx, [signer]);

  console.log("Transaction signature:", tx);
}

// Run the fillV3Relay function
fillV3Relay();
