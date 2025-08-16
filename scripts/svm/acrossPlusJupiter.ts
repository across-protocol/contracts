// This script implements Across+ fill where relayed tokens are swapped on Jupiter and sent to the final recipient via
// the message handler. Note that Jupiter swap works only on mainnet, so extra care should be taken to select output
// token, amounts and final recipient since this is a fake fill and relayer would not be refunded.

/**
 * Example run command:
 * anchor run acrossPlusJupiter --provider.cluster mainnet --provider.wallet ~/.config/solana/id.json -- \
  --recipient BgfHZYcwGT2czY8xzvH5PsCmHrgTgSZ1c4hQY9EteAC5 \
  --outputMint So11111111111111111111111111111111111111112 \
  --usdcValue 2.5 \
  --slippageBps 75
 */

import * as anchor from "@coral-xyz/anchor";
import { AnchorProvider, BN, Program, Wallet } from "@coral-xyz/anchor";
import {
  AccountMeta,
  TransactionInstruction,
  PublicKey,
  AddressLookupTableAccount,
  SendTransactionError,
  SolanaJSONRPCError,
  TransactionMessage,
  VersionedTransaction,
} from "@solana/web3.js";
import { BigNumber } from "ethers";
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
  createCloseAccountInstruction,
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
  MulticallHandlerCoder,
  sendTransactionWithLookupTable,
  loadFillRelayParamsWeb3V1,
  sendTransactionWithLookupTableWeb3V1,
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

const swapApiBaseUrl = "https://quote-api.jup.ag/v6/";

// Logging and Jupiter config
const LOG_PREFIX = "[AcrossPlus]";
const SOLANA_TX_SIZE_LIMIT = 1232;
const JUPITER_EXCLUDED_DEXES: string[] = [
  // Keep this list curated to avoid CPI depth/riskier venues
  "Stabble Stable Swap", // excluding because of CPI call depth
  "Stabble Weighted Swap", // same as above
  "Obric V2", // excluding because `Program log: AnchorError thrown in programs/obric-solana/src/instructions/swap_ixs.rs:331. Error Code: Rejected. Error Number: 6028. Error Message: Rejected.`
  "Meteora", // excluding because CPI call depth: Meteora Vault Program
];

// Helper to get a Jupiter quote + swap instructions, with logging and per-quote maxAccounts control.
const fetchJupiterQuoteAndIxs = async (opts: {
  label: string;
  inputMint: PublicKey;
  outputMint: PublicKey;
  amount: BigNumber;
  slippageBps: number;
  maxAccounts: number;
  excludeDexesCsv?: string;
  userPublicKey: PublicKey;
  wrapAndUnwrapSol?: boolean;
  minHops?: number;
}): Promise<{ quoteResponse: any; instructions: any }> => {
  const {
    label,
    inputMint,
    outputMint,
    amount,
    slippageBps,
    maxAccounts,
    excludeDexesCsv,
    userPublicKey,
    wrapAndUnwrapSol = false,
    minHops,
  } = opts;

  const quoteUrl =
    swapApiBaseUrl +
    "quote?inputMint=" +
    inputMint.toString() +
    "&outputMint=" +
    outputMint.toString() +
    "&amount=" +
    amount.toString() +
    "&slippageBps=" +
    String(slippageBps) +
    "&maxAccounts=" +
    String(maxAccounts) +
    (excludeDexesCsv ? "&excludeDexes=" + encodeURIComponent(excludeDexesCsv) : "");

  const quoteResponse = await (await fetch(quoteUrl)).json();
  if (quoteResponse.error) throw new Error("Failed to get quote: " + quoteResponse.error);

  if (typeof minHops === "number" && quoteResponse.routePlan && quoteResponse.routePlan.length < minHops) {
    throw new Error(
      `Quote returned only ${quoteResponse.routePlan.length} hop(s), which is less than requested minimum of ${minHops}`
    );
  }

  const instructions = await (
    await fetch(swapApiBaseUrl + "swap-instructions", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ quoteResponse, userPublicKey: userPublicKey.toString(), wrapAndUnwrapSol }),
    })
  ).json();
  if (instructions.error) throw new Error("Failed to get swap instructions: " + instructions.error);

  const altCount = Array.isArray(instructions.addressLookupTableAddresses)
    ? instructions.addressLookupTableAddresses.length
    : 0;
  const routePlan = Array.isArray(quoteResponse?.routePlan) ? quoteResponse.routePlan : [];
  console.log(`${LOG_PREFIX} ${label} swap planned: legs=${routePlan.length}, jupAlts=${altCount}`);
  if (routePlan.length > 0) {
    console.table(
      routePlan.map((leg: any, idx: number) => {
        const si = leg?.swapInfo || {};
        return {
          idx,
          label: si.label,
          percent: leg?.percent,
          inMint: si.inputMint,
          outMint: si.outputMint,
        };
      })
    );
  }

  return { quoteResponse, instructions };
};

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
  .option("maxAccountsMain", {
    type: "number",
    demandOption: false,
    describe: "Maximum swap accounts for the main output swap",
  })
  .option("maxAccountsGas", {
    type: "number",
    demandOption: false,
    describe: "Maximum swap accounts for the gas WSOL swap",
  })
  .option("priorityFeePrice", { type: "number", demandOption: false, describe: "Priority fee price in micro lamports" })
  .option("fillComputeUnit", { type: "number", demandOption: false, describe: "Compute unit limit in fill" })
  .option("gasUsd", {
    type: "string",
    demandOption: false,
    describe: "USDC value (formatted) to convert into SOL for gas top-up",
    default: "1",
  })
  .option("minHops", {
    type: "number",
    demandOption: false,
    describe: "Require at least this many swap legs (hops)",
  }).argv;

async function acrossPlusJupiter(): Promise<void> {
  const resolvedArgv = await argv;
  const seed = SOLANA_SPOKE_STATE_SEED; // Seed is always 0 for the state account PDA in public networks.
  const recipient = new PublicKey(resolvedArgv.recipient);
  const outputMint = new PublicKey(resolvedArgv.outputMint);
  const usdcAmount = parseUsdc(resolvedArgv.usdcValue);
  const slippageBps = resolvedArgv.slippageBps || 100; // default to 1%
  const minHops = resolvedArgv.minHops || 1;
  const maxAccountsMain = resolvedArgv.maxAccountsMain || 22;
  const maxAccountsGas = resolvedArgv.maxAccountsGas || 10;
  const priorityFeePrice = resolvedArgv.priorityFeePrice;
  const fillComputeUnit = resolvedArgv.fillComputeUnit || 2_000_000;
  const requestedGasUsdc: BigNumber = parseUsdc(resolvedArgv.gasUsd || "1");
  const wsolMint = new PublicKey("So11111111111111111111111111111111111111112");
  const isOutputWsol = outputMint.equals(wsolMint);
  let gasUsdcAmount: BigNumber = isOutputWsol ? BigNumber.from(0) : requestedGasUsdc;
  const excludeDexesCsv = JUPITER_EXCLUDED_DEXES.join(",");

  if (gasUsdcAmount.gt(0) && gasUsdcAmount.gte(usdcAmount)) {
    throw new Error("USDC amount too small for requested gasUsd top-up");
  }

  const mainUsdcAmount: BigNumber = usdcAmount.sub(gasUsdcAmount);

  const usdcMint = new PublicKey(SOLANA_USDC_MAINNET); // Only mainnet USDC is supported in this script.

  // Handler signer will swap tokens on Jupiter.
  const [handlerSigner] = PublicKey.findProgramAddressSync([Buffer.from("handler_signer")], handlerProgram.programId);

  // Focused error logger using typed web3 error classes
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

  // Get ATAs for the output mint.
  const outputMintInfo = await provider.connection.getAccountInfo(outputMint);
  if (!outputMintInfo) throw new Error("Output mint account not found");
  const outputTokenProgram = new PublicKey(outputMintInfo.owner);
  const recipientOutputTA = getAssociatedTokenAddressSync(outputMint, recipient, true, outputTokenProgram);
  const handlerOutputTA = getAssociatedTokenAddressSync(outputMint, handlerSigner, true, outputTokenProgram);

  // Will need lamports to potentially create ATAs: handler+recipient for output, and optionally handler WSOL.
  const rentExempt = await getMinimumBalanceForRentExemptAccount(provider.connection);
  const valueAmount = rentExempt * (2 + (gasUsdcAmount.gt(0) ? 1 : 0));

  console.log(`${LOG_PREFIX} Starting Across+ Jupiter fill`);
  console.table([
    { Property: "svmSpokeProgramProgramId", Value: svmSpokeProgram.programId.toString() },
    { Property: "handlerProgramId", Value: handlerProgram.programId.toString() },
    { Property: "recipient", Value: recipient.toString() },
    { Property: "recipientTA", Value: recipientOutputTA.toString() },
    { Property: "handlerOutputTA", Value: handlerOutputTA.toString() },
    { Property: "valueAmount", Value: valueAmount.toString() },
    { Property: "relayerPublicKey", Value: relayer.publicKey.toString() },
    { Property: "inputMint", Value: usdcMint.toString() },
    { Property: "outputMint", Value: outputMint.toString() },
    { Property: "usdcValue (formatted)", Value: formatUsdc(usdcAmount) },
    { Property: "gasUsd (formatted)", Value: formatUsdc(gasUsdcAmount) },
    { Property: "mainUsdc (formatted)", Value: formatUsdc(mainUsdcAmount) },
    { Property: "slippageBps", Value: slippageBps },
    { Property: "maxAccountsMain", Value: maxAccountsMain },
    { Property: "maxAccountsGas", Value: maxAccountsGas },
    { Property: "minHops", Value: minHops },
    { Property: "handlerSigner", Value: handlerSigner.toString() },
    { Property: "excludeDexes", Value: excludeDexesCsv || "<none>" },
  ]);

  // Get quote from Jupiter for main output swap
  const { quoteResponse: mainQuoteResponse, instructions: mainInstructions } = await fetchJupiterQuoteAndIxs({
    label: "Main",
    inputMint: usdcMint,
    outputMint,
    amount: mainUsdcAmount,
    slippageBps,
    maxAccounts: maxAccountsMain,
    excludeDexesCsv,
    userPublicKey: handlerSigner,
    wrapAndUnwrapSol: false,
    minHops,
  });

  // Optional gas swap: quote and get instructions for USDC -> WSOL -> close WSOL ATA to recipient to unwrap to SOL
  let gasInstructions: any | null = null;
  let gasQuoteResponse: any | null = null;
  if (gasUsdcAmount.gt(0)) {
    const result = await fetchJupiterQuoteAndIxs({
      label: "Gas",
      inputMint: usdcMint,
      outputMint: wsolMint,
      amount: gasUsdcAmount,
      slippageBps,
      maxAccounts: maxAccountsGas,
      excludeDexesCsv,
      userPublicKey: handlerSigner,
      wrapAndUnwrapSol: false,
    });
    gasQuoteResponse = result.quoteResponse;
    gasInstructions = result.instructions;
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

  // Load ALTs for both main and gas swaps (if any).
  const altAddrsSet = new Set<string>(mainInstructions.addressLookupTableAddresses || []);
  if (gasInstructions && gasInstructions.addressLookupTableAddresses) {
    for (const a of gasInstructions.addressLookupTableAddresses) altAddrsSet.add(a);
  }
  const addressLookupTableAccounts = await getAddressLookupTableAccounts(Array.from(altAddrsSet));
  console.log(`${LOG_PREFIX} Jupiter ALT tables provided:`, addressLookupTableAccounts.length);

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
    const innerCpiLimit = 10 * 1024;
    const innerCpiSize = transactionInstruction.keys.length * 34 + transactionInstruction.data.length;
    if (innerCpiSize > innerCpiLimit) {
      throw new Error(
        `Instruction too large for inner CPI: ${innerCpiSize} > ${innerCpiLimit}, try lowering maxAccounts`
      );
    }
    return transactionInstruction;
  };

  // Ignore Jupiter setup instructions as we need to create ATA both for the recipient and the handler signer.
  const [handlerOutputInfo, recipientOutputInfo] = await provider.connection.getMultipleAccountsInfo([
    handlerOutputTA,
    recipientOutputTA,
  ]);
  console.log(
    `${LOG_PREFIX} Output ATA existence [handler, recipient]:`,
    Boolean(handlerOutputInfo),
    Boolean(recipientOutputInfo)
  );
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
    mainQuoteResponse.otherAmountThreshold,
    outputDecimals,
    undefined,
    outputTokenProgram
  );

  // If gas swap is requested, prepare WSOL ATA for handler and close it to recipient after swap to unwrap to SOL.
  const handlerWsolTA = gasQuoteResponse ? getAssociatedTokenAddressSync(wsolMint, handlerSigner, true) : null;
  const createHandlerWsolATAInstruction = gasQuoteResponse
    ? createAssociatedTokenAccountIdempotentInstruction(
        handlerSigner,
        handlerWsolTA!,
        handlerSigner,
        wsolMint,
        TOKEN_PROGRAM_ID
      )
    : null;
  const closeHandlerWsolInstruction = gasQuoteResponse
    ? createCloseAccountInstruction(handlerWsolTA!, recipient, handlerSigner, [], TOKEN_PROGRAM_ID)
    : null;
  if (handlerWsolTA) {
    const [wsolInfo] = await provider.connection.getMultipleAccountsInfo([handlerWsolTA]);
    console.log(`${LOG_PREFIX} Handler WSOL ATA existence:`, Boolean(wsolInfo));
  }

  // Helpers for SPL and SOL balance reads
  const getSplAmountOrZero = async (account: PublicKey): Promise<bigint> => {
    try {
      const info = await provider.connection.getAccountInfo(account, { commitment: "confirmed" });
      if (!info) return 0n;
      const bal = await provider.connection.getTokenAccountBalance(account, "confirmed");
      return BigInt(bal.value.amount);
    } catch {
      return 0n;
    }
  };
  const getLamportsOrZero = async (account: PublicKey): Promise<bigint> => {
    const info = await provider.connection.getAccountInfo(account, { commitment: "confirmed" });
    return info ? BigInt(info.lamports) : 0n;
  };

  // Capture pre-transaction balances will be done later after USDC ATAs are ensured

  // Encode all instructions with handler PDA as the payer for ATA initialization.
  const mainSwapIx = deserializeInstruction(mainInstructions.swapInstruction);
  const multicallInstructions: TransactionInstruction[] = [
    createHandlerATAInstruction,
    mainSwapIx,
    createRecipientATAInstruction,
    transferInstruction,
  ];
  if (gasInstructions) {
    if (createHandlerWsolATAInstruction) multicallInstructions.push(createHandlerWsolATAInstruction);
    const gasSwapIx = deserializeInstruction(gasInstructions.swapInstruction);
    multicallInstructions.push(gasSwapIx);
    if (closeHandlerWsolInstruction) multicallInstructions.push(closeHandlerWsolInstruction);
  }
  console.log(`${LOG_PREFIX} Multicall instructions prepared:`, multicallInstructions.length);

  const multicallHandlerCoder = new MulticallHandlerCoder(multicallInstructions, handlerSigner);
  const handlerMessage = multicallHandlerCoder.encode();
  const message = new AcrossPlusMessageCoder({
    handler: handlerProgram.programId,
    readOnlyLen: multicallHandlerCoder.readOnlyLen,
    valueAmount: new BN(valueAmount), // Must exactly cover ATA creation.
    accounts: multicallHandlerCoder.compiledMessage.accountKeys,
    handlerMessage,
  });
  const encodedMessage = message.encode();
  console.log(
    `${LOG_PREFIX} Encoded handler message: keyCount=${multicallHandlerCoder.compiledMessage.accountKeys.length}, ` +
      `handlerBytes=${handlerMessage.length}, encodedBytes=${encodedMessage.length}`
  );

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
    inputAmount: intToU8Array32(new BN(usdcAmount.toString())),
    outputAmount: new BN(usdcAmount.toString()),
    originChainId: new BN(CHAIN_IDs.MAINNET), // This is not a real deposit, so use MAINNET as origin chain id.
    depositId: intToU8Array32(new BN(Math.random() * 2 ** 32)), // This is not a real deposit, use random deposit id.
    fillDeadline: Math.floor(Date.now() / 1000) + 60, // Current time + 1 minute
    exclusivityDeadline: Math.floor(Date.now() / 1000) + 30, // Current time + 30 seconds
    message: encodedMessage,
  };
  const relayHashUint8Array = calculateRelayHashUint8Array(relayData, solanaChainId);
  console.log(`${LOG_PREFIX} Relay data prepared`);
  console.table(
    Object.entries(relayData)
      .map(([key, value]) => ({
        key,
        value: value.toString(),
      }))
      .filter((entry) => entry.key !== "message") // Message is printed separately.
  );
  console.log(`${LOG_PREFIX} Relay message (hex):`, relayData.message.toString("hex"));

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

  // Capture pre-transaction balances for analysis
  const preBalances = {
    handlerUsdc: await getSplAmountOrZero(handlerUsdcTA),
    handlerOutput: await getSplAmountOrZero(handlerOutputTA),
    recipientOutput: await getSplAmountOrZero(recipientOutputTA),
    handlerWsol: handlerWsolTA ? await getSplAmountOrZero(handlerWsolTA) : 0n,
    recipientLamports: await getLamportsOrZero(recipient),
  };

  // Fetch the state from the on-chain program to get chainId
  const state = await svmSpokeProgram.account.state.fetch(statePda);
  const chainId = new BN(state.chainId);
  const delegate = getFillRelayDelegatePda(
    relayHashUint8Array,
    chainId,
    relayer.publicKey,
    svmSpokeProgram.programId
  ).pda;

  // Delegate state PDA to pull relayer USDC tokens.
  const usdcDecimals = (await getMint(provider.connection, usdcMint)).decimals;
  const approveIx = createApproveCheckedInstruction(
    relayerUsdcTA,
    usdcMint, // == outputToken
    delegate,
    relayer.publicKey,
    BigInt(relayData.outputAmount.toString()),
    usdcDecimals,
    undefined,
    TOKEN_PROGRAM_ID
  );

  // Reporter to compare pre/post balances and minOut thresholds
  const reportPostSwapDeltas = async (txSig: string) => {
    try {
      await provider.connection.confirmTransaction(txSig, "confirmed");
    } catch {}

    const postBalances = {
      handlerUsdc: await getSplAmountOrZero(handlerUsdcTA),
      handlerOutput: await getSplAmountOrZero(handlerOutputTA),
      recipientOutput: await getSplAmountOrZero(recipientOutputTA),
      handlerWsol: handlerWsolTA ? await getSplAmountOrZero(handlerWsolTA) : 0n,
      recipientLamports: await getLamportsOrZero(recipient),
    };

    const minMainOut = BigInt(String(mainQuoteResponse.otherAmountThreshold ?? 0));
    const minGasOut = gasQuoteResponse ? BigInt(String(gasQuoteResponse.otherAmountThreshold ?? 0)) : 0n;
    const recipientOutputDelta = postBalances.recipientOutput - preBalances.recipientOutput;
    const handlerOutputDelta = postBalances.handlerOutput - preBalances.handlerOutput;
    const handlerOutputLeft = postBalances.handlerOutput;
    const recipientLamportsDelta = postBalances.recipientLamports - preBalances.recipientLamports;

    const usdcInFromFill = BigInt(usdcAmount.toString());
    const expectedUsdcSpent = usdcInFromFill; // main + gas should equal total usdcAmount
    const actualUsdcSpent = preBalances.handlerUsdc + usdcInFromFill - postBalances.handlerUsdc;
    const usdcSpentDelta = actualUsdcSpent - expectedUsdcSpent;

    console.log(`${LOG_PREFIX} Min output thresholds:`);
    console.table(
      [
        { kind: "Main", mint: outputMint.toBase58(), minOutRaw: minMainOut.toString(), decimals: outputDecimals },
        gasQuoteResponse
          ? { kind: "Gas(WSOL)", mint: "So1111...1112", minOutRaw: minGasOut.toString(), decimals: 9 }
          : undefined,
      ].filter(Boolean) as any[]
    );

    console.log(`${LOG_PREFIX} Post-swap deltas and balances:`);
    console.table([
      { metric: "recipientOutputDelta", value: recipientOutputDelta.toString(), mint: outputMint.toBase58() },
      { metric: "handlerOutputDelta", value: handlerOutputDelta.toString(), mint: outputMint.toBase58() },
      { metric: "handlerOutputLeft", value: handlerOutputLeft.toString(), mint: outputMint.toBase58() },
      { metric: "recipientLamportsDelta", value: recipientLamportsDelta.toString() },
    ]);

    console.log(`${LOG_PREFIX} Inspect ATAs in a block explorer:`);
    console.table(
      [
        { label: "handler USDC ATA", address: handlerUsdcTA.toBase58() },
        { label: "handler output ATA", address: handlerOutputTA.toBase58() },
        { label: "recipient output ATA", address: recipientOutputTA.toBase58() },
        handlerWsolTA ? { label: "handler WSOL ATA", address: handlerWsolTA.toBase58() } : undefined,
      ].filter(Boolean) as any[]
    );

    console.log(`${LOG_PREFIX} Handler USDC flow check (exact-in expectation)`);
    console.table([
      { field: "preHandlerUsdc", raw: preBalances.handlerUsdc.toString(), decimals: usdcDecimals },
      { field: "fillTransferIn", raw: usdcInFromFill.toString(), decimals: usdcDecimals },
      { field: "expectedSpent", raw: expectedUsdcSpent.toString(), decimals: usdcDecimals },
      { field: "postHandlerUsdc", raw: postBalances.handlerUsdc.toString(), decimals: usdcDecimals },
      { field: "actualSpent", raw: actualUsdcSpent.toString(), decimals: usdcDecimals },
      { field: "spentDelta(actual-expected)", raw: usdcSpentDelta.toString(), decimals: usdcDecimals },
    ]);
  };

  // Prepare fill instruction.
  const fillV3RelayValues: FillDataValues = [
    Array.from(relayHashUint8Array),
    relayData,
    solanaChainId,
    relayer.publicKey,
  ];
  try {
    await loadFillRelayParamsWeb3V1(
      svmSpokeProgram,
      relayer,
      fillV3RelayValues[1],
      fillV3RelayValues[2],
      fillV3RelayValues[3],
      priorityFeePrice
    );
  } catch (err: any) {
    await logTxError(err, "loadFillRelayParams");
    throw err;
  }
  const [instructionParams] = PublicKey.findProgramAddressSync(
    [Buffer.from("instruction_params"), relayer.publicKey.toBuffer()],
    svmSpokeProgram.programId
  );

  const fillRelayParams: FillDataParams = [fillV3RelayValues[0], null, null, null];
  const fillAccounts = {
    state: statePda,
    signer: relayer.publicKey,
    delegate,
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
  console.log(`${LOG_PREFIX} Fill remaining accounts:`, fillRemainingAccounts.length);
  const fillIx = await svmSpokeProgram.methods
    .fillRelay(...fillRelayParams)
    .accounts(fillAccounts)
    .remainingAccounts(fillRemainingAccounts)
    .instruction();
  console.log(`${LOG_PREFIX} Fill instruction prepared: keys=${fillIx.keys.length}, dataLen=${fillIx.data.length}`);

  const finalIxs = prependComputeBudgetWeb3V1([approveIx, fillIx], priorityFeePrice, fillComputeUnit);
  const finalPrograms = new Set<string>();
  const finalAccounts = new Set<string>();
  for (const ix of finalIxs) {
    finalPrograms.add(ix.programId.toBase58());
    ix.keys.forEach((k) => finalAccounts.add(k.pubkey.toBase58()));
  }
  console.log(`${LOG_PREFIX} Final ixs: ${finalIxs.length}, uniqueAccounts=${finalAccounts.size}`);
  console.log(`${LOG_PREFIX} Compute budget:`, { priorityFeePrice, fillComputeUnit });

  // Preflight compile and measure serialized size to confirm packet overflow root cause
  let preflightBytes: number | null = null;
  let noAltBytes: number | null = null;
  let preflightOverflow = false;
  try {
    const { blockhash } = await provider.connection.getLatestBlockhash();
    const msgV0 = new TransactionMessage({
      payerKey: relayer.publicKey,
      recentBlockhash: blockhash,
      instructions: finalIxs,
    }).compileToV0Message(addressLookupTableAccounts);

    const vt = new VersionedTransaction(msgV0);
    vt.sign([relayer]);
    const bytes = vt.serialize();
    const lookups = msgV0.addressTableLookups || [];
    preflightBytes = bytes.length;
    console.log(
      `${LOG_PREFIX} Preflight (with Jupiter ALTs): bytes=${bytes.length}, staticKeys=${
        msgV0.staticAccountKeys?.length ?? null
      }, lookupTables=${lookups.length}`
    );
    if (bytes.length > SOLANA_TX_SIZE_LIMIT) preflightOverflow = true;

    // Also estimate without ALTs to approximate savings
    try {
      const msgNoAlt = new TransactionMessage({
        payerKey: relayer.publicKey,
        recentBlockhash: blockhash,
        instructions: finalIxs,
      }).compileToV0Message([]);
      const vtNoAlt = new VersionedTransaction(msgNoAlt);
      vtNoAlt.sign([relayer]);
      noAltBytes = vtNoAlt.serialize().length;
      if (typeof noAltBytes === "number") {
        console.log(
          `${LOG_PREFIX} Preflight (no ALTs): bytes=${noAltBytes}, staticKeys=${
            msgNoAlt.staticAccountKeys?.length ?? null
          }`
        );
      }
    } catch {}
  } catch (e) {
    console.log(`${LOG_PREFIX} Preflight compile failed:`, (e as Error).message);
    preflightOverflow = true;
  }

  // Compute simple metrics about accounts and tables for reporting
  const lookupAddressesSet = new Set<string>();
  for (const ix of finalIxs) {
    lookupAddressesSet.add(ix.programId.toBase58());
    ix.keys.forEach((k) => lookupAddressesSet.add(k.pubkey.toBase58()));
  }
  const totalUniqueAccounts = lookupAddressesSet.size;
  const jupAltTables = addressLookupTableAccounts.length;
  const jupAltAddresses = addressLookupTableAccounts.reduce((acc, a) => acc + a.state.addresses.length, 0);
  const localLutExtendTxs = Math.ceil(totalUniqueAccounts / 30);
  console.log(
    `${LOG_PREFIX} Metrics: txBytes=${
      preflightBytes ?? "<unknown>"
    }, jupAltTables=${jupAltTables}, jupAltAddresses=${jupAltAddresses}, uniqueAccounts=${totalUniqueAccounts}`
  );
  if (preflightOverflow) {
    console.log(
      `${LOG_PREFIX} Preflight overflow detected; sending with a single local ALT (${localLutExtendTxs} extend txs)`
    );
    try {
      const txSignature = await sendTransactionWithLookupTableWeb3V1(provider.connection, finalIxs, relayer);
      console.log(`${LOG_PREFIX} Fill transaction signature:`, txSignature);
      await reportPostSwapDeltas(txSignature);
    } catch (err: any) {
      await logTxError(err, "sendTransaction-localLUT");
      throw err;
    }
  } else {
    const saved =
      typeof noAltBytes === "number" && typeof preflightBytes === "number" ? noAltBytes - preflightBytes : null;
    console.log(
      `${LOG_PREFIX} Using Jupiter ALTs (no local ALT).` +
        (typeof saved === "number" ? ` Approx bytes saved vs no-ALT: ~${saved}` : "")
    );
    try {
      const txSignature = await sendTransactionWithLookupTableWeb3V1(
        provider.connection,
        finalIxs,
        relayer,
        addressLookupTableAccounts
      );
      console.log(`${LOG_PREFIX} Fill transaction signature:`, txSignature);
      await reportPostSwapDeltas(txSignature);
    } catch (err: any) {
      await logTxError(err, "sendTransaction-jupALTs");
      throw err;
    }
  }
}

acrossPlusJupiter();
