// This script implements a fill where relayed tokens are distributed to random recipients via the message handler.
// Note that this should be run only on devnet as this is fake fill and all filled tokens are sent to random recipients.
import * as anchor from "@coral-xyz/anchor";
import { AnchorProvider, BN } from "@coral-xyz/anchor";
import {
  ASSOCIATED_TOKEN_PROGRAM_ID,
  TOKEN_PROGRAM_ID,
  createApproveCheckedInstruction,
  createTransferCheckedInstruction,
  getAssociatedTokenAddressSync,
  getMint,
  getOrCreateAssociatedTokenAccount,
} from "@solana/spl-token";
import { AccountMeta, Keypair, PublicKey, SystemProgram, TransactionInstruction } from "@solana/web3.js";
import yargs from "yargs";
import { hideBin } from "yargs/helpers";
import {
  AcrossPlusMessageCoder,
  MulticallHandlerCoder,
  calculateRelayHashUint8Array,
  getSpokePoolProgram,
  loadFillV3RelayParams,
  sendTransactionWithLookupTable,
} from "../../src/svm";
import { FillDataParams, FillDataValues } from "../../src/types/svm";

// Set up the provider and signer.
const provider = AnchorProvider.env();
anchor.setProvider(provider);
const signer = (anchor.AnchorProvider.env().wallet as anchor.Wallet).payer;

const program = getSpokePoolProgram(provider);
const programId = program.programId;

// Parse arguments
const argv = yargs(hideBin(process.argv))
  .option("depositor", { type: "string", demandOption: true, describe: "Depositor public key" })
  .option("handler", { type: "string", demandOption: true, describe: "Handler program ID" })
  .option("exclusiveRelayer", { type: "string", demandOption: false, describe: "Exclusive relayer public key" })
  .option("inputToken", { type: "string", demandOption: true, describe: "Input token public key" })
  .option("outputToken", { type: "string", demandOption: true, describe: "Output token public key" })
  .option("inputAmount", { type: "number", demandOption: true, describe: "Input amount" })
  .option("outputAmount", { type: "number", demandOption: true, describe: "Output amount" })
  .option("originChainId", { type: "string", demandOption: true, describe: "Origin chain ID" })
  .option("depositId", { type: "array", demandOption: true, describe: "Deposit ID" })
  .option("fillDeadline", { type: "number", demandOption: false, describe: "Fill deadline" })
  .option("exclusivityDeadline", { type: "number", demandOption: false, describe: "Exclusivity deadline" })
  .option("repaymentChain", { type: "number", demandOption: false, description: "Repayment chain ID" })
  .option("repaymentAddress", { type: "string", demandOption: false, description: "Repayment address" })
  .option("distributionCount", { type: "number", demandOption: false, describe: "Distribution count" })
  .option("bufferParams", { type: "boolean", demandOption: false, describe: "Use buffer account for params" }).argv;

async function fillV3RelayToRandom(): Promise<void> {
  const resolvedArgv = await argv;
  const depositor = new PublicKey(resolvedArgv.depositor);
  const handler = new PublicKey(resolvedArgv.handler);
  const exclusiveRelayer = new PublicKey(resolvedArgv.exclusiveRelayer || PublicKey.default.toString());
  const inputToken = new PublicKey(resolvedArgv.inputToken);
  const outputToken = new PublicKey(resolvedArgv.outputToken);
  const inputAmount = new BN(resolvedArgv.inputAmount);
  const outputAmount = new BN(resolvedArgv.outputAmount);
  const originChainId = new BN(resolvedArgv.originChainId);
  const depositId = (resolvedArgv.depositId as number[]).map((id) => id); // Ensure depositId is an array of BN
  const fillDeadline = resolvedArgv.fillDeadline || Math.floor(Date.now() / 1000) + 60; // Current time + 1 minute
  const exclusivityDeadline = resolvedArgv.exclusivityDeadline || Math.floor(Date.now() / 1000) + 30; // Current time + 30 seconds
  const repaymentChain = new BN(resolvedArgv.repaymentChain || 1);
  const repaymentAddress = new PublicKey(resolvedArgv.repaymentAddress || signer.publicKey.toString());
  const seed = new BN(0);
  const distributionCount = resolvedArgv.distributionCount || 1;
  const bufferParams = resolvedArgv.bufferParams || false;

  const tokenDecimals = (await getMint(provider.connection, outputToken)).decimals;

  // Filled relay will first send tokens to the handler ATA.
  const [handlerSigner] = PublicKey.findProgramAddressSync([Buffer.from("handler_signer")], handler);
  const handlerATA = (
    await getOrCreateAssociatedTokenAccount(provider.connection, signer, outputToken, handlerSigner, true)
  ).address;

  // Populate random final recipients and transfer instructions.
  const recipientAccounts: PublicKey[] = [];
  const transferInstructions: TransactionInstruction[] = [];
  for (let i = 0; i < distributionCount; i++) {
    const recipient = Keypair.generate().publicKey;
    const recipientATA = (await getOrCreateAssociatedTokenAccount(provider.connection, signer, outputToken, recipient))
      .address;
    recipientAccounts.push(recipientATA);

    // Construct ix to transfer tokens from handler to the recipient in equal distribution (except the last one getting any rounding remainder).
    const distributionAmount =
      i !== distributionCount - 1
        ? outputAmount.div(new BN(distributionCount))
        : outputAmount.sub(outputAmount.div(new BN(distributionCount)).mul(new BN(distributionCount - 1)));
    const transferInstruction = createTransferCheckedInstruction(
      handlerATA,
      outputToken,
      recipientATA,
      handlerSigner,
      BigInt(distributionAmount.toString()),
      tokenDecimals
    );
    transferInstructions.push(transferInstruction);
  }

  // Encode handler message for the token distribution.
  const multicallHandlerCoder = new MulticallHandlerCoder(transferInstructions);
  const handlerMessage = multicallHandlerCoder.encode();
  const message = new AcrossPlusMessageCoder({
    handler,
    readOnlyLen: multicallHandlerCoder.readOnlyLen,
    valueAmount: new BN(0),
    accounts: multicallHandlerCoder.compiledMessage.accountKeys,
    handlerMessage,
  });
  const encodedMessage = message.encode();

  const relayData = {
    depositor,
    recipient: handlerSigner,
    exclusiveRelayer,
    inputToken,
    outputToken,
    inputAmount,
    outputAmount,
    originChainId,
    depositId,
    fillDeadline,
    exclusivityDeadline,
    message: encodedMessage,
  };

  console.log("Filling V3 Relay with handler...");

  // Define the state account PDA
  const [statePda] = PublicKey.findProgramAddressSync(
    [Buffer.from("state"), seed.toArrayLike(Buffer, "le", 8)],
    programId
  );

  // Fetch the state from the on-chain program to get chainId
  const state = await program.account.state.fetch(statePda);
  const chainId = new BN(state.chainId);

  const relayHashUint8Array = calculateRelayHashUint8Array(relayData, chainId);
  const relayHash = Array.from(relayHashUint8Array);

  // Define the fill status account PDA
  const [fillStatusPda] = PublicKey.findProgramAddressSync([Buffer.from("fills"), relayHashUint8Array], programId);

  // Get ATA for the relayer token account
  const relayerTokenAccount = getAssociatedTokenAddressSync(outputToken, signer.publicKey);

  console.table([
    { property: "relayHash", value: Buffer.from(relayHashUint8Array).toString("hex") },
    { property: "chainId", value: chainId.toString() },
    { property: "programId", value: programId.toString() },
    { property: "providerPublicKey", value: provider.wallet.publicKey.toString() },
    { property: "statePda", value: statePda.toString() },
    { property: "fillStatusPda", value: fillStatusPda.toString() },
    { property: "relayerTokenAccount", value: relayerTokenAccount.toString() },
    { property: "recipientTokenAccount", value: handlerATA.toString() },
    { property: "seed", value: seed.toString() },
  ]);

  console.log("Relay Data:");
  console.table(
    Object.entries(relayData).map(([key, value]) => ({
      key,
      value: key === "message" ? (value as Buffer).toString("hex") : value.toString(),
    }))
  );

  // Delegate state PDA to pull relayer tokens.
  const approveInstruction = await createApproveCheckedInstruction(
    relayerTokenAccount,
    outputToken,
    statePda,
    signer.publicKey,
    BigInt(relayData.outputAmount.toString()),
    tokenDecimals,
    undefined,
    TOKEN_PROGRAM_ID
  );

  // Prepare fill instruction as we will need to use Address Lookup Table (ALT).
  const fillV3RelayValues: FillDataValues = [relayHash, relayData, repaymentChain, repaymentAddress];
  if (bufferParams) {
    await loadFillV3RelayParams(program, signer, fillV3RelayValues[1], fillV3RelayValues[2], fillV3RelayValues[3]);
  }
  const fillV3RelayParams: FillDataParams = bufferParams ? [fillV3RelayValues[0], null, null, null] : fillV3RelayValues;
  const [instructionParams] = bufferParams
    ? PublicKey.findProgramAddressSync(
        [Buffer.from("instruction_params"), signer.publicKey.toBuffer()],
        program.programId
      )
    : [program.programId];

  const fillAccounts = {
    state: statePda,
    signer: signer.publicKey,
    instructionParams,
    mint: outputToken,
    relayerTokenAccount,
    recipientTokenAccount: handlerATA,
    fillStatus: fillStatusPda,
    tokenProgram: TOKEN_PROGRAM_ID,
    associatedTokenProgram: ASSOCIATED_TOKEN_PROGRAM_ID,
    systemProgram: SystemProgram.programId,
    program: programId,
  };
  const remainingAccounts: AccountMeta[] = [
    { pubkey: handler, isSigner: false, isWritable: false },
    ...multicallHandlerCoder.compiledKeyMetas,
  ];
  const fillInstruction = await program.methods
    .fillV3Relay(...fillV3RelayParams)
    .accounts(fillAccounts)
    .remainingAccounts(remainingAccounts)
    .instruction();

  // Fill using the ALT.
  const { txSignature } = await sendTransactionWithLookupTable(
    provider.connection,
    [approveInstruction, fillInstruction],
    signer
  );

  console.log("Transaction signature:", txSignature);
}

// Run the fillV3RelayToRandom function
fillV3RelayToRandom();
