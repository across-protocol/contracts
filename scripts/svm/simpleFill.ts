// This script implements a simple relayer fill against known deposit props. Note that if the deposit data is done wrong
// this script can easily create invalid fills.

import * as anchor from "@coral-xyz/anchor";
import { AnchorProvider, BN } from "@coral-xyz/anchor";
import {
  ASSOCIATED_TOKEN_PROGRAM_ID,
  TOKEN_PROGRAM_ID,
  createApproveCheckedInstruction,
  getAssociatedTokenAddressSync,
  getMint,
  getOrCreateAssociatedTokenAccount,
} from "@solana/spl-token";
import { PublicKey, SystemProgram, Transaction, sendAndConfirmTransaction } from "@solana/web3.js";
import yargs from "yargs";
import { hideBin } from "yargs/helpers";
import { calculateRelayHashUint8Array, getSpokePoolProgram, intToU8Array32 } from "../../src/svm/web3-v1";
import { FillDataValues } from "../../src/types/svm";

// Set up the provider
const provider = AnchorProvider.env();
anchor.setProvider(provider);
const program = getSpokePoolProgram(provider);
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
  .option("depositId", { type: "string", demandOption: true, describe: "Deposit ID" })
  .option("fillDeadline", { type: "number", demandOption: false, describe: "Fill deadline" })
  .option("exclusivityDeadline", { type: "number", demandOption: false, describe: "Exclusivity deadline" }).argv;

async function fillRelay(): Promise<void> {
  const resolvedArgv = await argv;
  const depositor = new PublicKey(resolvedArgv.depositor);
  const recipient = new PublicKey(resolvedArgv.recipient);
  const exclusiveRelayer = new PublicKey(resolvedArgv.exclusiveRelayer || "11111111111111111111111111111111");
  const inputToken = new PublicKey(resolvedArgv.inputToken);
  const outputToken = new PublicKey(resolvedArgv.outputToken);
  const inputAmount = new BN(resolvedArgv.inputAmount);
  const outputAmount = new BN(resolvedArgv.outputAmount);
  const originChainId = new BN(resolvedArgv.originChainId);
  const depositId = intToU8Array32(new BN(resolvedArgv.depositId));
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
    depositId,
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

  // Create the ATA using the create_token_accounts method
  const createTokenAccountsIx = await program.methods
    .createTokenAccounts()
    .accounts({ signer: signer.publicKey, mint: outputToken, tokenProgram: TOKEN_PROGRAM_ID })
    .remainingAccounts([
      { pubkey: recipient, isWritable: false, isSigner: false },
      { pubkey: recipientTokenAccount, isWritable: true, isSigner: false },
    ])
    .instruction();

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

  const fillDataValues: FillDataValues = [Array.from(relayHashUint8Array), relayData, chainId, signer.publicKey];

  const fillAccounts = {
    state: statePda,
    signer: signer.publicKey,
    instructionParams: program.programId,
    mint: outputToken,
    relayerTokenAccount: relayerTokenAccount,
    recipientTokenAccount: recipientTokenAccount,
    fillStatus: fillStatusPda,
    tokenProgram: TOKEN_PROGRAM_ID,
    associatedTokenProgram: ASSOCIATED_TOKEN_PROGRAM_ID,
    systemProgram: SystemProgram.programId,
    programId: programId,
    program: program.programId,
  };

  const fillIx = await program.methods
    .fillRelay(...fillDataValues)
    .accounts(fillAccounts)
    .instruction();

  const fillTx = new Transaction().add(createTokenAccountsIx, approveIx, fillIx);
  const tx = await sendAndConfirmTransaction(provider.connection, fillTx, [signer]);

  console.log("Transaction signature:", tx);
}

// Run the fillV3Relay function
fillRelay();
