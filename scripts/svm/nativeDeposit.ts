// This script is used to initiate a native token Solana deposit. useful in testing.

import * as anchor from "@coral-xyz/anchor";
import { AnchorProvider, BN } from "@coral-xyz/anchor";
import {
  ASSOCIATED_TOKEN_PROGRAM_ID,
  createApproveCheckedInstruction,
  createAssociatedTokenAccountIdempotentInstruction,
  createCloseAccountInstruction,
  createSyncNativeInstruction,
  getAssociatedTokenAddressSync,
  getMinimumBalanceForRentExemptAccount,
  getMint,
  NATIVE_MINT,
  TOKEN_PROGRAM_ID,
} from "@solana/spl-token";
import {
  PublicKey,
  sendAndConfirmTransaction,
  SystemProgram,
  Transaction,
  TransactionInstruction,
} from "@solana/web3.js";
import yargs from "yargs";
import { hideBin } from "yargs/helpers";
import {
  getDepositPda,
  getDepositSeedHash,
  getSpokePoolProgram,
  intToU8Array32,
  SOLANA_SPOKE_STATE_SEED,
  u8Array32ToInt,
} from "../../src/svm/web3-v1";

// Set up the provider
const provider = AnchorProvider.env();
anchor.setProvider(provider);
const program = getSpokePoolProgram(provider);
const programId = program.programId;
console.log("SVM-Spoke Program ID:", programId.toString());

// Parse arguments
const argv = yargs(hideBin(process.argv))
  .option("recipient", { type: "string", demandOption: true, describe: "Recipient public key" })
  .option("outputToken", { type: "string", demandOption: true, describe: "Output token public key" })
  .option("inputAmount", { type: "number", demandOption: true, describe: "Input amount" })
  .option("outputAmount", { type: "string", demandOption: true, describe: "Output amount" })
  .option("destinationChainId", { type: "string", demandOption: true, describe: "Destination chain ID" })
  .option("integratorId", { type: "string", demandOption: false, describe: "integrator ID" }).argv;

async function nativeDeposit(): Promise<void> {
  const resolvedArgv = await argv;
  const seed = SOLANA_SPOKE_STATE_SEED;
  const recipient = new PublicKey(resolvedArgv.recipient);
  const inputToken = NATIVE_MINT;
  const outputToken = new PublicKey(resolvedArgv.outputToken);
  const inputAmount = new BN(resolvedArgv.inputAmount);
  const outputAmount = intToU8Array32(new BN(resolvedArgv.outputAmount));
  const destinationChainId = new BN(resolvedArgv.destinationChainId);
  const exclusiveRelayer = PublicKey.default;
  const quoteTimestamp = Math.floor(Date.now() / 1000) - 1;
  const fillDeadline = quoteTimestamp + 3600; // 1 hour from now
  const exclusivityDeadline = 0;
  const message = Buffer.from([]); // Convert to Buffer
  const integratorId = resolvedArgv.integratorId || "";
  // Define the state account PDA
  const [statePda, _] = PublicKey.findProgramAddressSync(
    [Buffer.from("state"), seed.toArrayLike(Buffer, "le", 8)],
    programId
  );

  // Define the signer (replace with your actual signer)
  const signer = (provider.wallet as anchor.Wallet).payer;

  // Find ATA for the input token to be stored by state (vault).
  const vault = getAssociatedTokenAddressSync(
    inputToken,
    statePda,
    true,
    TOKEN_PROGRAM_ID,
    ASSOCIATED_TOKEN_PROGRAM_ID
  );

  const userTokenAccount = getAssociatedTokenAddressSync(inputToken, signer.publicKey);
  const userTokenAccountInfo = await provider.connection.getAccountInfo(userTokenAccount);
  const existingTokenAccount = userTokenAccountInfo !== null && userTokenAccountInfo.owner.equals(TOKEN_PROGRAM_ID);

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
    { property: "userTokenAccount", value: userTokenAccount.toString() },
    { property: "existingTokenAccount", value: existingTokenAccount },
  ]);

  const tokenDecimals = (await getMint(provider.connection, inputToken, undefined, TOKEN_PROGRAM_ID)).decimals;

  // Will need to add rent exemption to the deposit amount if the user token account does not exist.
  const rentExempt = existingTokenAccount ? 0 : await getMinimumBalanceForRentExemptAccount(provider.connection);
  const transferIx = SystemProgram.transfer({
    fromPubkey: signer.publicKey,
    toPubkey: userTokenAccount,
    lamports: BigInt(inputAmount.toString()) + BigInt(rentExempt),
  });

  // Create wSOL user account if it doesn't exist, otherwise sync its native balance.
  const syncOrCreateIx = existingTokenAccount
    ? createSyncNativeInstruction(userTokenAccount)
    : createAssociatedTokenAccountIdempotentInstruction(
        signer.publicKey,
        userTokenAccount,
        signer.publicKey,
        inputToken
      );

  // Close the user token account if it did not exist before.
  const lastIxs = existingTokenAccount
    ? []
    : [createCloseAccountInstruction(userTokenAccount, signer.publicKey, signer.publicKey)];

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

  const depositIx = await program.methods
    .deposit(
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
    )
    .accounts(depositAccounts)
    .instruction();

  // Create the deposit transaction
  const depositTx = new Transaction().add(transferIx, syncOrCreateIx, approveIx, depositIx, ...lastIxs);

  if (integratorId !== "") {
    const MemoIx = new TransactionInstruction({
      keys: [{ pubkey: signer.publicKey, isSigner: true, isWritable: true }],
      data: Buffer.from(integratorId, "utf-8"),
      programId: new PublicKey("MemoSq4gqABAXKb96qnH8TysNcWxMyWCqXgDLGmfcHr"), // Memo program ID
    });
    depositTx.add(MemoIx);
  }

  const tx = await sendAndConfirmTransaction(provider.connection, depositTx, [signer]);
  console.log("Transaction signature:", tx);
}

// Run the nativeDeposit function
nativeDeposit();
