// This script implements Across+ fill where relayed tokens are swapped on Jupiter and sent to the final recipient via
// the message handler. Note that Jupiter swap works only on mainnet, so extra care should be taken to select output
// token, amounts and final recipient since this is a fake fill and relayer would not be refunded.

import * as anchor from "@coral-xyz/anchor";
import { AnchorProvider, BN, Program, Wallet } from "@coral-xyz/anchor";
import { AccountMeta, TransactionInstruction, PublicKey, AddressLookupTableAccount } from "@solana/web3.js";
import fetch from "cross-fetch";
import yargs from "yargs";
import { hideBin } from "yargs/helpers";
import { SvmSpoke } from "../../target/types/svm_spoke";
import { MulticallHandler } from "../../target/types/multicall_handler";
import { formatUsdc, parseUsdc } from "./utils/helpers";
import {
  ASSOCIATED_TOKEN_PROGRAM_ID,
  createApproveCheckedInstruction,
  createAssociatedTokenAccountIdempotentInstruction,
  createTransferCheckedInstruction,
  getAssociatedTokenAddressSync,
  getMinimumBalanceForRentExemptAccount,
  getMint,
  getOrCreateAssociatedTokenAccount,
  TOKEN_PROGRAM_ID,
} from "@solana/spl-token";
import {
  AcrossPlusMessageCoder,
  calculateRelayHashUint8Array,
  intToU8Array32,
  loadFillV3RelayParams,
  MulticallHandlerCoder,
  prependComputeBudget,
  sendTransactionWithLookupTable,
  getSolanaChainId,
  isSolanaDevnet,
  SOLANA_SPOKE_STATE_SEED,
  SOLANA_USDC_MAINNET,
} from "../../src/svm";
import { CHAIN_IDs } from "../../utils/constants";
import { FillDataParams, FillDataValues } from "../../src/types/svm";

const swapApiBaseUrl = "https://quote-api.jup.ag/v6/";

// Set up Solana provider and signer.
const provider = AnchorProvider.env();
anchor.setProvider(provider);
const relayer = (provider.wallet as Wallet).payer;

// Get Solana programs.
const svmSpokeIdl = require("../../target/idl/svm_spoke.json");
const svmSpokeProgram = new Program<SvmSpoke>(svmSpokeIdl, provider);
const handlerIdl = require("../../target/idl/multicall_handler.json");
const handlerProgram = new Program<MulticallHandler>(handlerIdl, provider);

if (isSolanaDevnet(provider)) throw new Error("This script is only for mainnet");

// Parse arguments
const argv = yargs(hideBin(process.argv))
  .option("recipient", { type: "string", demandOption: true, describe: "Recipient public key" })
  .option("outputMint", { type: "string", demandOption: true, describe: "Token to receive from the swap" })
  .option("usdcValue", { type: "string", demandOption: true, describe: "USDC value bridged/swapped (formatted)" })
  .option("slippageBps", { type: "number", demandOption: false, describe: "Custom slippage in bps" })
  .option("maxAccounts", { type: "number", demandOption: false, describe: "Maximum swap accounts" })
  .option("priorityFeePrice", { type: "number", demandOption: false, describe: "Priority fee price in micro lamports" })
  .option("fillComputeUnit", { type: "number", demandOption: false, describe: "Compute unit limit in fill" }).argv;

async function acrossPlusJupiter(): Promise<void> {
  const resolvedArgv = await argv;
  const seed = SOLANA_SPOKE_STATE_SEED; // Seed is always 0 for the state account PDA in public networks.
  const recipient = new PublicKey(resolvedArgv.recipient);
  const outputMint = new PublicKey(resolvedArgv.outputMint);
  const usdcAmount = parseUsdc(resolvedArgv.usdcValue);
  const slippageBps = resolvedArgv.slippageBps || 100; // default to 1%
  const maxAccounts = resolvedArgv.maxAccounts || 24;
  const priorityFeePrice = resolvedArgv.priorityFeePrice;
  const fillComputeUnit = resolvedArgv.fillComputeUnit || 400_000;

  const usdcMint = new PublicKey(SOLANA_USDC_MAINNET); // Only mainnet USDC is supported in this script.

  // Handler signer will swap tokens on Jupiter.
  const [handlerSigner] = PublicKey.findProgramAddressSync([Buffer.from("handler_signer")], handlerProgram.programId);

  // Get ATAs for the output mint.
  const outputMintInfo = await provider.connection.getAccountInfo(outputMint);
  if (!outputMintInfo) throw new Error("Output mint account not found");
  const outputTokenProgram = new PublicKey(outputMintInfo.owner);
  const recipientOutputTA = getAssociatedTokenAddressSync(outputMint, recipient, true, outputTokenProgram);
  const handlerOutputTA = getAssociatedTokenAddressSync(outputMint, handlerSigner, true, outputTokenProgram);

  // Will need lamports to potentially create ATA both for the recipient and the handler signer.
  const valueAmount = (await getMinimumBalanceForRentExemptAccount(provider.connection)) * 2;

  console.log("Filling Across+ swap...");
  console.table([
    { Property: "svmSpokeProgramProgramId", Value: svmSpokeProgram.programId.toString() },
    { Property: "handlerProgramId", Value: handlerProgram.programId.toString() },
    { Property: "recipient", Value: recipient.toString() },
    { Property: "recipientTA", Value: recipientOutputTA.toString() },
    { Property: "valueAmount", Value: valueAmount.toString() },
    { Property: "relayerPublicKey", Value: relayer.publicKey.toString() },
    { Property: "inputMint", Value: usdcMint.toString() },
    { Property: "outputMint", Value: outputMint.toString() },
    { Property: "usdcValue (formatted)", Value: formatUsdc(usdcAmount) },
    { Property: "slippageBps", Value: slippageBps },
    { Property: "maxAccounts", Value: maxAccounts },
    { Property: "handlerSigner", Value: handlerSigner.toString() },
  ]);

  // Get quote from Jupiter.
  const quoteResponse = await (
    await fetch(
      swapApiBaseUrl +
        "quote?inputMint=" +
        usdcMint.toString() +
        "&outputMint=" +
        outputMint.toString() +
        "&amount=" +
        usdcAmount +
        "&slippageBps=" +
        slippageBps +
        "&maxAccounts=" +
        maxAccounts
    )
  ).json();
  if (quoteResponse.error) {
    throw new Error("Failed to get quote: " + quoteResponse.error);
  }

  // Create swap instructions on behalf of the handler signer. We do not enable unwrapping of WSOL as that would require
  // additional logic to handle transferring SOL from the handler signer to the recipient.
  const wrapAndUnwrapSol = false;
  const instructions = await (
    await fetch(swapApiBaseUrl + "swap-instructions", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ quoteResponse, userPublicKey: handlerSigner.toString(), wrapAndUnwrapSol }),
    })
  ).json();
  if (instructions.error) {
    throw new Error("Failed to get swap instructions: " + instructions.error);
  }

  // Helper to load Jupiter ALTs.
  const getAddressLookupTableAccounts = async (keys: string[]): Promise<AddressLookupTableAccount[]> => {
    const addressLookupTableAccountInfos = await provider.connection.getMultipleAccountsInfo(
      keys.map((key) => new PublicKey(key))
    );

    return addressLookupTableAccountInfos.reduce((acc: AddressLookupTableAccount[], accountInfo, index) => {
      const addressLookupTableAddress = keys[index];
      if (accountInfo) {
        const addressLookupTableAccount = new AddressLookupTableAccount({
          key: new PublicKey(addressLookupTableAddress),
          state: AddressLookupTableAccount.deserialize(accountInfo.data),
        });
        acc.push(addressLookupTableAccount);
      }

      return acc;
    }, []);
  };

  const addressLookupTableAccounts = await getAddressLookupTableAccounts(instructions.addressLookupTableAddresses);

  // Helper to deserialize instruction and check if it would fit in inner CPI limit.
  const deserializeInstruction = (instruction: any) => {
    const transactionInstruction = new TransactionInstruction({
      programId: new PublicKey(instruction.programId),
      keys: instruction.accounts.map((key: any) => ({
        pubkey: new PublicKey(key.pubkey),
        isSigner: key.isSigner,
        isWritable: key.isWritable,
      })),
      data: Buffer.from(instruction.data, "base64"),
    });
    const innerCpiLimit = 1280;
    const innerCpiSize = transactionInstruction.keys.length * 34 + transactionInstruction.data.length;
    if (innerCpiSize > innerCpiLimit) {
      throw new Error(
        `Instruction too large for inner CPI: ${innerCpiSize} > ${innerCpiLimit}, try lowering maxAccounts`
      );
    }
    return transactionInstruction;
  };

  // Ignore Jupiter setup instructions as we need to create ATA both for the recipient and the handler signer.
  const createHandlerATAInstruction = createAssociatedTokenAccountIdempotentInstruction(
    handlerSigner,
    handlerOutputTA,
    handlerSigner,
    outputMint,
    outputTokenProgram
  );
  const createRecipientATAInstruction = createAssociatedTokenAccountIdempotentInstruction(
    handlerSigner,
    recipientOutputTA,
    recipient,
    outputMint,
    outputTokenProgram
  );

  // Construct ix to transfer minimum output tokens from handler to the recipient ATA. Note that all remaining tokens
  // can be stolen by anyone. This could be improved by creating a sweeper program that reads actual handler ATA balance
  // and transfers all of them to the recipient ATA.
  const outputDecimals = (await getMint(provider.connection, outputMint, undefined, outputTokenProgram)).decimals;
  const transferInstruction = createTransferCheckedInstruction(
    handlerOutputTA,
    outputMint,
    recipientOutputTA,
    handlerSigner,
    quoteResponse.otherAmountThreshold,
    outputDecimals,
    undefined,
    outputTokenProgram
  );

  // Encode all instructions with handler PDA as the payer for ATA initialization.
  const multicallHandlerCoder = new MulticallHandlerCoder(
    [
      createHandlerATAInstruction,
      deserializeInstruction(instructions.swapInstruction),
      createRecipientATAInstruction,
      transferInstruction,
    ],
    handlerSigner
  );
  const handlerMessage = multicallHandlerCoder.encode();
  const message = new AcrossPlusMessageCoder({
    handler: handlerProgram.programId,
    readOnlyLen: multicallHandlerCoder.readOnlyLen,
    valueAmount: new BN(valueAmount), // Must exactly cover ATA creation.
    accounts: multicallHandlerCoder.compiledMessage.accountKeys,
    handlerMessage,
  });
  const encodedMessage = message.encode();

  // Define the state account PDA
  const [statePda] = PublicKey.findProgramAddressSync(
    [Buffer.from("state"), seed.toArrayLike(Buffer, "le", 8)],
    svmSpokeProgram.programId
  );

  // This script works only on mainnet.
  const solanaChainId = new BN(getSolanaChainId("mainnet").toString());

  // Construct relay data.
  const relayData = {
    depositor: recipient, // This is not a real deposit, so use recipient as depositor.
    recipient: handlerSigner,
    exclusiveRelayer: PublicKey.default,
    inputToken: usdcMint, // This is not a real deposit, so use the same USDC as input token.
    outputToken: usdcMint, // USDC is output token for the bridge and input token for the swap.
    inputAmount: new BN(usdcAmount.toString()), // This is not a real deposit, so use the same USDC amount as input amount.
    outputAmount: new BN(usdcAmount.toString()),
    originChainId: new BN(CHAIN_IDs.MAINNET), // This is not a real deposit, so use MAINNET as origin chain id.
    depositId: intToU8Array32(new BN(Math.random() * 2 ** 32)), // This is not a real deposit, use random deposit id.
    fillDeadline: Math.floor(Date.now() / 1000) + 60, // Current time + 1 minute
    exclusivityDeadline: Math.floor(Date.now() / 1000) + 30, // Current time + 30 seconds
    message: encodedMessage,
  };
  const relayHashUint8Array = calculateRelayHashUint8Array(relayData, solanaChainId);
  console.log("Relay Data:");
  console.table(
    Object.entries(relayData)
      .map(([key, value]) => ({
        key,
        value: value.toString(),
      }))
      .filter((entry) => entry.key !== "message") // Message is printed separately.
  );
  console.log("Relay message:", relayData.message.toString("hex"));

  // Define the fill status account PDA
  const [fillStatusPda] = PublicKey.findProgramAddressSync(
    [Buffer.from("fills"), relayHashUint8Array],
    svmSpokeProgram.programId
  );

  // Create ATA for the relayer and handler USDC token accounts
  const relayerUsdcTA = getAssociatedTokenAddressSync(usdcMint, relayer.publicKey, true);
  const handlerUsdcTA = (
    await getOrCreateAssociatedTokenAccount(provider.connection, relayer, usdcMint, handlerSigner, true, "confirmed")
  ).address;

  // Delegate state PDA to pull relayer USDC tokens.
  const usdcDecimals = (await getMint(provider.connection, usdcMint)).decimals;
  const approveIx = await createApproveCheckedInstruction(
    relayerUsdcTA,
    usdcMint,
    statePda,
    relayer.publicKey,
    BigInt(usdcAmount.toString()),
    usdcDecimals
  );

  // Prepare fill instruction.
  const fillV3RelayValues: FillDataValues = [
    Array.from(relayHashUint8Array),
    relayData,
    solanaChainId,
    relayer.publicKey,
  ];
  await loadFillV3RelayParams(
    svmSpokeProgram,
    relayer,
    fillV3RelayValues[1],
    fillV3RelayValues[2],
    fillV3RelayValues[3],
    priorityFeePrice
  );
  const [instructionParams] = PublicKey.findProgramAddressSync(
    [Buffer.from("instruction_params"), relayer.publicKey.toBuffer()],
    svmSpokeProgram.programId
  );

  const fillV3RelayParams: FillDataParams = [fillV3RelayValues[0], null, null, null];
  const fillAccounts = {
    state: statePda,
    signer: relayer.publicKey,
    instructionParams,
    mint: usdcMint,
    relayerTokenAccount: relayerUsdcTA,
    recipientTokenAccount: handlerUsdcTA,
    fillStatus: fillStatusPda,
    tokenProgram: TOKEN_PROGRAM_ID,
    associatedTokenProgram: ASSOCIATED_TOKEN_PROGRAM_ID,
    program: svmSpokeProgram.programId,
  };
  const fillRemainingAccounts: AccountMeta[] = [
    { pubkey: handlerProgram.programId, isSigner: false, isWritable: false },
    ...multicallHandlerCoder.compiledKeyMetas,
  ];
  const fillIx = await svmSpokeProgram.methods
    .fillV3Relay(...fillV3RelayParams)
    .accounts(fillAccounts)
    .remainingAccounts(fillRemainingAccounts)
    .instruction();

  // Fill using the ALT with the provided compute budget settings.
  const txSignature = await sendTransactionWithLookupTable(
    provider.connection,
    prependComputeBudget([approveIx, fillIx], priorityFeePrice, fillComputeUnit),
    relayer,
    addressLookupTableAccounts
  );
  console.log("Fill transaction signature:", txSignature);
}

acrossPlusJupiter();
