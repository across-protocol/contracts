// A simple Across+ fill script that forwards a fixed amount of SOL (via value_amount)
// and forwards the remaining bridged USDC to the user using the MulticallHandler.
//
// Key properties:
// - No Jupiter swaps. The SOL is sent using value_amount transfer inside the SVM Spoke program
//   (see message_utils.rs), which transfers lamports from the relayer to the first message account.
// - We avoid pre-populated instruction params; relay_data is passed inline to fillRelay.
// - We attempt to keep the transaction small: handler message contains a single SPL transfer instruction.
//
// Example:
// anchor run acrossPlusValueForward --provider.cluster mainnet --provider.wallet ~/.config/solana/id.json -- \
//   --recipient <SOL_PUBKEY> \
//   --usdcValue 10

import * as anchor from "@coral-xyz/anchor";
import { AnchorProvider, BN, Program, Wallet } from "@coral-xyz/anchor";
import {
  AccountMeta,
  PublicKey,
  TransactionInstruction,
  SendTransactionError,
  SolanaJSONRPCError,
  Transaction,
  sendAndConfirmTransaction,
  TransactionMessage,
  VersionedTransaction,
} from "@solana/web3.js";
import yargs from "yargs";
import { hideBin } from "yargs/helpers";
import { BigNumber } from "ethers";
import {
  ASSOCIATED_TOKEN_PROGRAM_ID,
  createApproveCheckedInstruction,
  createAssociatedTokenAccountIdempotentInstruction,
  createTransferCheckedInstruction,
  getAssociatedTokenAddressSync,
  getMint,
  TOKEN_PROGRAM_ID,
} from "@solana/spl-token";
import { SvmSpoke } from "../../target/types/svm_spoke";
import { MulticallHandler } from "../../target/types/multicall_handler";
import {
  AcrossPlusMessageCoder,
  MulticallHandlerCoder,
  calculateRelayHashUint8Array,
  prependComputeBudgetWeb3V1,
} from "../../src/svm";
import { CHAIN_IDs } from "../../utils/constants";
import { FillDataParams, FillDataValues } from "../../src/types/svm";
import {
  getFillRelayDelegatePda,
  getSolanaChainId,
  intToU8Array32,
  isSolanaDevnet,
  SOLANA_SPOKE_STATE_SEED,
  SOLANA_USDC_MAINNET,
} from "../../src/svm/web3-v1";

// Set up Solana provider and signer
const provider = AnchorProvider.env();
anchor.setProvider(provider);
const relayer = (provider.wallet as Wallet).payer;

// Programs
const svmSpokeIdl = require("../../target/idl/svm_spoke.json");
const svmSpokeProgram = new Program<SvmSpoke>(svmSpokeIdl, provider);
const handlerIdl = require("../../target/idl/multicall_handler.json");
const handlerProgram = new Program<MulticallHandler>(handlerIdl, provider);

if (isSolanaDevnet(provider)) throw new Error("This script is only for mainnet");

const LOG_PREFIX = "[AcrossPlusValue]";

const argv = yargs(hideBin(process.argv))
  .option("recipient", { type: "string", demandOption: true, describe: "Final user SOL public key" })
  .option("usdcValue", { type: "string", demandOption: true, describe: "Total USDC bridged (formatted)" })
  .option("priorityFeePrice", { type: "number", demandOption: false, describe: "Priority fee price in micro lamports" })
  .option("fillComputeUnit", { type: "number", demandOption: false, describe: "Compute unit limit in fill" }).argv;

async function acrossPlusValueForward(): Promise<void> {
  const resolved = await argv;
  const recipient = new PublicKey(resolved.recipient);
  const usdcAmount = BigNumber.from(Math.round(parseFloat(resolved.usdcValue) * 1_000_000)); // 6 decimals
  const priorityFeePrice = resolved.priorityFeePrice as number | undefined;
  const fillComputeUnit = resolved.fillComputeUnit as number | undefined;

  // Compute value_amount from $200/SOL: 1 USDC ≈ 0.005 SOL = 5_000_000 lamports.
  const LAMPORTS_PER_SOL = BigNumber.from(1_000_000_000);
  const USD_PER_SOL = BigNumber.from(200);
  const LAMPORTS_PER_USD = LAMPORTS_PER_SOL.div(USD_PER_SOL); // 5_000_000
  const valueLamports = LAMPORTS_PER_USD; // Always forward ~1 USDC worth of SOL

  // 1 USDC goes to SOL (forwarded as lamports); the rest goes out as USDC.
  const oneUsdc = BigNumber.from(1_000_000);
  if (usdcAmount.lte(oneUsdc)) throw new Error("USDC amount must be greater than 1 USDC");
  const usdcToUser = usdcAmount.sub(oneUsdc);

  // State PDA and chainId
  const seed = SOLANA_SPOKE_STATE_SEED;
  const [statePda] = PublicKey.findProgramAddressSync(
    [Buffer.from("state"), seed.toArrayLike(Buffer, "le", 8)],
    svmSpokeProgram.programId
  );
  const state = await svmSpokeProgram.account.state.fetch(statePda);
  const chainId = new BN(state.chainId);

  const solanaChainId = new BN(getSolanaChainId("mainnet").toString());
  const usdcMint = new PublicKey(SOLANA_USDC_MAINNET);

  // Multicall handler signer PDA
  const [handlerSigner] = PublicKey.findProgramAddressSync([Buffer.from("handler_signer")], handlerProgram.programId);

  // Relayer and handler USDC ATAs (no pre-create RPC; all created idempotently inside the same tx)
  // Determine token program for USDC mint to derive correct ATAs
  const usdcMintInfo = await provider.connection.getAccountInfo(usdcMint);
  if (!usdcMintInfo) throw new Error("USDC mint account not found");
  const usdcTokenProgram = new PublicKey(usdcMintInfo.owner);

  const relayerUsdcTA = getAssociatedTokenAddressSync(usdcMint, relayer.publicKey, true, usdcTokenProgram);
  const handlerUsdcTA = getAssociatedTokenAddressSync(usdcMint, handlerSigner, true, usdcTokenProgram);

  // Recipient USDC ATA. Create idempotently in the same tx.
  const recipientUsdcTA = getAssociatedTokenAddressSync(usdcMint, recipient, true, usdcTokenProgram);
  const createRecipientAtaIx = createAssociatedTokenAccountIdempotentInstruction(
    relayer.publicKey,
    recipientUsdcTA,
    recipient,
    usdcMint,
    usdcTokenProgram
  );
  const createHandlerAtaIx = createAssociatedTokenAccountIdempotentInstruction(
    relayer.publicKey,
    handlerUsdcTA,
    handlerSigner,
    usdcMint,
    usdcTokenProgram
  );

  const usdcDecimals = (await getMint(provider.connection, usdcMint)).decimals;

  // Build a single-token transfer from handler -> recipient for (usdcAmount - 1 USDC)
  const transferIx = createTransferCheckedInstruction(
    handlerUsdcTA,
    usdcMint,
    recipientUsdcTA,
    handlerSigner,
    BigInt(usdcToUser.toString()),
    usdcDecimals,
    undefined,
    usdcTokenProgram
  );

  // Encode handler message. Payer key for MulticallHandlerCoder is set to the SOL recipient so that
  // the first compiled account equals the SOL recipient, and value_amount is transferred to them.
  const multicallHandlerCoder = new MulticallHandlerCoder([transferIx], recipient);
  const handlerMessage = multicallHandlerCoder.encode();
  const message = new AcrossPlusMessageCoder({
    handler: handlerProgram.programId,
    readOnlyLen: multicallHandlerCoder.readOnlyLen,
    valueAmount: new BN(valueLamports.toString()),
    accounts: multicallHandlerCoder.compiledMessage.accountKeys,
    handlerMessage,
  });
  const encodedMessage = message.encode();

  // Relay data: inputAmount reflects total USDC bridged; outputAmount excludes the 1 USDC used for SOL value.
  const relayData = {
    depositor: recipient, // not a real bridge deposit; align with demo pattern
    recipient: handlerSigner,
    exclusiveRelayer: PublicKey.default,
    inputToken: usdcMint,
    outputToken: usdcMint,
    inputAmount: intToU8Array32(new BN(usdcAmount.toString())),
    outputAmount: new BN(usdcToUser.toString()),
    originChainId: new BN(CHAIN_IDs.MAINNET),
    depositId: intToU8Array32(new BN(Math.floor(Math.random() * 2 ** 32))),
    fillDeadline: Math.floor(Date.now() / 1000) + 60,
    exclusivityDeadline: Math.floor(Date.now() / 1000) + 30,
    message: encodedMessage,
  };

  const relayHashUint8Array = calculateRelayHashUint8Array(relayData, solanaChainId);
  const [fillStatusPda] = PublicKey.findProgramAddressSync(
    [Buffer.from("fills"), relayHashUint8Array],
    svmSpokeProgram.programId
  );

  // Approve delegate to pull the exact outputAmount into handler signer account
  const delegate = getFillRelayDelegatePda(
    relayHashUint8Array,
    chainId,
    relayer.publicKey,
    svmSpokeProgram.programId
  ).pda;
  const approveIx = createApproveCheckedInstruction(
    relayerUsdcTA,
    usdcMint,
    delegate,
    relayer.publicKey,
    BigInt(usdcToUser.toString()),
    usdcDecimals,
    undefined,
    usdcTokenProgram
  );

  // Compose fill call without prepopulated instruction params
  const fillRelayValues: FillDataValues = [
    Array.from(relayHashUint8Array),
    relayData,
    solanaChainId,
    relayer.publicKey,
  ];
  const fillRelayParams: FillDataParams = fillRelayValues;

  const fillAccounts = {
    state: statePda,
    signer: relayer.publicKey,
    delegate,
    instructionParams: svmSpokeProgram.programId, // unused when passing inline relay_data
    mint: usdcMint,
    relayerTokenAccount: relayerUsdcTA,
    recipientTokenAccount: handlerUsdcTA,
    fillStatus: fillStatusPda,
    tokenProgram: usdcTokenProgram,
    associatedTokenProgram: ASSOCIATED_TOKEN_PROGRAM_ID,
    program: svmSpokeProgram.programId,
  };
  const remainingAccounts: AccountMeta[] = [
    { pubkey: handlerProgram.programId, isSigner: false, isWritable: false },
    ...multicallHandlerCoder.compiledKeyMetas,
  ];

  const fillIx = await svmSpokeProgram.methods
    .fillRelay(...fillRelayParams)
    .accounts(fillAccounts)
    .remainingAccounts(remainingAccounts)
    .instruction();

  const ixs: TransactionInstruction[] = [];
  // Create both ATAs idempotently inside the same tx, then approve and fill
  ixs.push(createHandlerAtaIx, createRecipientAtaIx, approveIx, fillIx);

  const finalIxs = prependComputeBudgetWeb3V1(ixs, priorityFeePrice, fillComputeUnit);

  // Preflight serialize estimate against 1232-byte limit (v0 msg, no ALTs)
  const SOLANA_TX_SIZE_LIMIT = 1232;
  let preflightBytes: number | null = null;
  try {
    const { blockhash } = await provider.connection.getLatestBlockhash();
    const msgV0 = new TransactionMessage({
      payerKey: relayer.publicKey,
      recentBlockhash: blockhash,
      instructions: finalIxs,
    }).compileToV0Message([]);
    const vt = new VersionedTransaction(msgV0);
    vt.sign([relayer]);
    preflightBytes = vt.serialize().length;
    console.log(`${LOG_PREFIX} Preflight: bytes=${preflightBytes}, limit=${SOLANA_TX_SIZE_LIMIT}`);
  } catch (e) {
    console.log(`${LOG_PREFIX} Preflight compile failed:`, (e as Error).message);
  }

  try {
    const tx = new Transaction().add(...finalIxs);
    const txSig = await sendAndConfirmTransaction(provider.connection, tx, [relayer], {
      commitment: "confirmed",
      skipPreflight: false,
    });
    console.log(`${LOG_PREFIX} Transaction signature:`, txSig);
    console.table([
      { property: "recipient", value: recipient.toBase58() },
      { property: "usdcAmount", value: usdcAmount.toString() },
      { property: "usdcToUser", value: usdcToUser.toString() },
      { property: "valueLamports", value: valueLamports.toString() },
      { property: "preflightBytes", value: String(preflightBytes ?? "<unknown>") },
    ]);
  } catch (err) {
    await logTxError(err, "sendTransaction");
    throw err;
  }
}

// Focused error logger
const logTxError = async (err: unknown, label: string) => {
  if (err instanceof SendTransactionError) {
    const txErr = err.transactionError;
    const logs = (await err.getLogs(provider.connection).catch(() => undefined)) || err.logs;
    console.error(`${LOG_PREFIX} ${label} SendTransactionError:`, txErr?.message || err.message);
    if (logs && logs.length) console.error(`${LOG_PREFIX} ${label} logs:`, logs);
    return;
  }
  if (err instanceof SolanaJSONRPCError) {
    console.error(`${LOG_PREFIX} ${label} RPC error [${String(err.code)}]:`, err.message);
    const dataLogs = (err as any)?.data?.logs;
    if (Array.isArray(dataLogs)) console.error(`${LOG_PREFIX} ${label} RPC logs:`, dataLogs);
    return;
  }
  const anyErr = err as any;
  console.error(`${LOG_PREFIX} ${label} error:`, anyErr?.message || String(err));
  if (Array.isArray(anyErr?.data?.logs)) console.error(`${LOG_PREFIX} ${label} logs:`, anyErr.data.logs);
};

acrossPlusValueForward();
