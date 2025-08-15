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
  .option("fillComputeUnit", { type: "number", demandOption: false, describe: "Compute unit limit in fill" })
  .option("gasUsd", {
    type: "string",
    demandOption: false,
    describe: "USDC value (formatted) to convert into SOL for gas top-up",
    default: "1",
  })
  .option("excludeDexes", {
    type: "string",
    demandOption: false,
    describe: "Comma-separated list of DEX labels to exclude in Jupiter quotes (e.g. 'Lifinity V2,Orca')",
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
  const maxAccounts = resolvedArgv.maxAccounts || 24;
  const priorityFeePrice = resolvedArgv.priorityFeePrice;
  const fillComputeUnit = resolvedArgv.fillComputeUnit || 2_000_000;
  const requestedGasUsdc: BigNumber = parseUsdc(resolvedArgv.gasUsd || "1");
  const wsolMint = new PublicKey("So11111111111111111111111111111111111111112");
  const isOutputWsol = outputMint.equals(wsolMint);
  let gasUsdcAmount: BigNumber = isOutputWsol ? BigNumber.from(0) : requestedGasUsdc;
  const autoExcludeDexes = ["Stabble Stable Swap"]; // mitigate CPI depth seen in trace
  const userExcludeDexes = (resolvedArgv.excludeDexes || "")
    .split(",")
    .map((s: string) => s.trim())
    .filter((s: string) => s.length > 0);
  const excludeDexesCsv = Array.from(new Set([...userExcludeDexes, ...autoExcludeDexes])).join(",");

  if (gasUsdcAmount.gt(0) && gasUsdcAmount.gte(usdcAmount)) {
    throw new Error("USDC amount too small for requested gasUsd top-up");
  }

  const mainUsdcAmount: BigNumber = usdcAmount.sub(gasUsdcAmount);

  const usdcMint = new PublicKey(SOLANA_USDC_MAINNET); // Only mainnet USDC is supported in this script.

  // Handler signer will swap tokens on Jupiter.
  const [handlerSigner] = PublicKey.findProgramAddressSync([Buffer.from("handler_signer")], handlerProgram.programId);

  // Robust error logger for send/confirm errors (handles different shapes of web3 errors)
  const logTxError = async (err: any, label: string) => {
    try {
      console.log(`USER_DEBUG_OVERFLOW ${label} error:`, err?.message || String(err));
      const maybeSTE = err as SendTransactionError;
      if (maybeSTE && typeof maybeSTE.getLogs === "function") {
        const logs = await maybeSTE.getLogs(provider.connection);
        console.log(`USER_DEBUG_OVERFLOW ${label} getLogs:`, logs);
        return;
      }
      if (Array.isArray(err?.transactionLogs)) {
        console.log(`USER_DEBUG_OVERFLOW ${label} transactionLogs:`, err.transactionLogs);
        return;
      }
      if (Array.isArray(err?.logs)) {
        console.log(`USER_DEBUG_OVERFLOW ${label} logs:`, err.logs);
        return;
      }
      if (Array.isArray(err?.data?.logs)) {
        console.log(`USER_DEBUG_OVERFLOW ${label} data.logs:`, err.data.logs);
        return;
      }
    } catch (inner: any) {
      console.log(`USER_DEBUG_OVERFLOW ${label} logging failed:`, inner?.message || String(inner));
    }
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
    { Property: "gasUsd (formatted)", Value: formatUsdc(gasUsdcAmount) },
    { Property: "mainUsdc (formatted)", Value: formatUsdc(mainUsdcAmount) },
    { Property: "slippageBps", Value: slippageBps },
    { Property: "maxAccounts", Value: maxAccounts },
    { Property: "minHops", Value: minHops },
    { Property: "handlerSigner", Value: handlerSigner.toString() },
    { Property: "excludeDexes", Value: excludeDexesCsv || "<none>" },
  ]);

  // Get quote from Jupiter for main output swap.
  const quoteResponse = await (
    await fetch(
      swapApiBaseUrl +
        "quote?inputMint=" +
        usdcMint.toString() +
        "&outputMint=" +
        outputMint.toString() +
        "&amount=" +
        mainUsdcAmount.toString() +
        "&slippageBps=" +
        slippageBps +
        "&maxAccounts=" +
        maxAccounts +
        (excludeDexesCsv ? "&excludeDexes=" + encodeURIComponent(excludeDexesCsv) : "")
    )
  ).json();
  if (quoteResponse.error) {
    throw new Error("Failed to get quote: " + quoteResponse.error);
  }

  if (quoteResponse.routePlan && quoteResponse.routePlan.length < minHops) {
    throw new Error(
      `Quote returned only ${quoteResponse.routePlan.length} hop(s), which is less than requested minimum of ${minHops}`
    );
  }

  // Create swap instructions for main output on behalf of the handler signer. No auto unwrap for main output.
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
  console.log(
    "USER_DEBUG_OVERFLOW main swap: routePlanLen, altCount",
    Array.isArray(quoteResponse.routePlan) ? quoteResponse.routePlan.length : null,
    Array.isArray(instructions.addressLookupTableAddresses) ? instructions.addressLookupTableAddresses.length : 0
  );
  if (Array.isArray(instructions.addressLookupTableAddresses)) {
    console.log("USER_DEBUG_OVERFLOW main swap ALT addresses:", instructions.addressLookupTableAddresses);
  }
  // USER_DEBUG_ROUTE: planned main route legs and venues
  try {
    const rp = Array.isArray(quoteResponse?.routePlan) ? quoteResponse.routePlan : [];
    console.log("USER_DEBUG_ROUTE main: legs=", rp.length);
    if (rp.length > 0) {
      console.table(
        rp.map((leg: any, idx: number) => {
          const si = leg?.swapInfo || {};
          return {
            idx,
            label: si.label,
            ammKey: leg?.ammKey,
            percent: leg?.percent,
            inMint: si.inputMint,
            outMint: si.outputMint,
            inAmount: String(si.inAmount ?? ""),
            outAmount: String(si.outAmount ?? ""),
          };
        })
      );
    }
  } catch (_) {}

  // Optional gas top-up: quote and instructions for USDC -> WSOL (we will close WSOL ATA to recipient to unwrap safely).
  let gasInstructions: any | null = null;
  let gasQuoteResponse: any | null = null;
  if (gasUsdcAmount.gt(0)) {
    gasQuoteResponse = await (
      await fetch(
        swapApiBaseUrl +
          "quote?inputMint=" +
          usdcMint.toString() +
          "&outputMint=So11111111111111111111111111111111111111112" +
          "&amount=" +
          gasUsdcAmount.toString() +
          "&slippageBps=" +
          slippageBps +
          "&maxAccounts=" +
          maxAccounts +
          (excludeDexesCsv ? "&excludeDexes=" + encodeURIComponent(excludeDexesCsv) : "")
      )
    ).json();
    if (gasQuoteResponse.error) {
      throw new Error("Failed to get gas quote: " + gasQuoteResponse.error);
    }

    // Don't require minHops adherence from a gas swap
    // if (gasQuoteResponse.routePlan && gasQuoteResponse.routePlan.length < minHops) {
    //   throw new Error(
    //     `Gas quote returned only ${gasQuoteResponse.routePlan.length} hop(s), which is less than requested minimum of ${minHops}`
    //   );
    // }

    const gasWrapAndUnwrapSol = false;
    gasInstructions = await (
      await fetch(swapApiBaseUrl + "swap-instructions", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          quoteResponse: gasQuoteResponse,
          userPublicKey: handlerSigner.toString(),
          wrapAndUnwrapSol: gasWrapAndUnwrapSol,
        }),
      })
    ).json();
    if (gasInstructions.error) {
      throw new Error("Failed to get gas swap instructions: " + gasInstructions.error);
    }
    console.log(
      "USER_DEBUG_OVERFLOW gas swap: routePlanLen, altCount",
      Array.isArray(gasQuoteResponse.routePlan) ? gasQuoteResponse.routePlan.length : null,
      Array.isArray(gasInstructions.addressLookupTableAddresses)
        ? gasInstructions.addressLookupTableAddresses.length
        : 0
    );
    if (Array.isArray(gasInstructions.addressLookupTableAddresses)) {
      console.log("USER_DEBUG_OVERFLOW gas swap ALT addresses:", gasInstructions.addressLookupTableAddresses);
    }
    // USER_DEBUG_ROUTE: planned gas route legs and venues
    try {
      const rp = Array.isArray(gasQuoteResponse?.routePlan) ? gasQuoteResponse.routePlan : [];
      console.log("USER_DEBUG_ROUTE gas: legs=", rp.length);
      if (rp.length > 0) {
        console.table(
          rp.map((leg: any, idx: number) => {
            const si = leg?.swapInfo || {};
            return {
              idx,
              label: si.label,
              ammKey: leg?.ammKey,
              percent: leg?.percent,
              inMint: si.inputMint,
              outMint: si.outputMint,
              inAmount: String(si.inAmount ?? ""),
              outAmount: String(si.outAmount ?? ""),
            };
          })
        );
      }
    } catch (_) {}
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
  const altAddrsSet = new Set<string>(instructions.addressLookupTableAddresses || []);
  if (gasInstructions && gasInstructions.addressLookupTableAddresses) {
    for (const a of gasInstructions.addressLookupTableAddresses) altAddrsSet.add(a);
  }
  const addressLookupTableAccounts = await getAddressLookupTableAccounts(Array.from(altAddrsSet));
  console.log("USER_DEBUG_OVERFLOW union ALT count:", addressLookupTableAccounts.length);
  console.log(
    "USER_DEBUG_OVERFLOW union ALT keys:",
    addressLookupTableAccounts.map((a) => a.key.toBase58())
  );

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
    console.log(
      "USER_DEBUG_OVERFLOW JUP ix program, keys, dataLen, innerCpiSize:",
      transactionInstruction.programId.toBase58(),
      transactionInstruction.keys.length,
      transactionInstruction.data.length,
      innerCpiSize
    );
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
    "USER_DEBUG_OVERFLOW output ATA existence [handler,recipient]:",
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
    quoteResponse.otherAmountThreshold,
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
    console.log("USER_DEBUG_OVERFLOW handler WSOL ATA existence:", Boolean(wsolInfo));
  }

  // Encode all instructions with handler PDA as the payer for ATA initialization.
  const mainSwapIx = deserializeInstruction(instructions.swapInstruction);
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
  console.log(
    "USER_DEBUG_OVERFLOW multicall ixs (programId, keys, dataLen):",
    multicallInstructions.map((ix) => [ix.programId.toBase58(), ix.keys.length, ix.data.length])
  );

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
    "USER_DEBUG_OVERFLOW compiledMessage accountKeys len:",
    multicallHandlerCoder.compiledMessage.accountKeys.length
  );
  console.log("USER_DEBUG_OVERFLOW compiledKeyMetas len:", multicallHandlerCoder.compiledKeyMetas.length);
  console.log("USER_DEBUG_OVERFLOW readOnlyLen:", multicallHandlerCoder.readOnlyLen);
  console.log("USER_DEBUG_OVERFLOW handlerMessage bytes:", handlerMessage.length);
  console.log("USER_DEBUG_OVERFLOW encodedMessage bytes:", encodedMessage.length);

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
  console.log("USER_DEBUG_OVERFLOW fillRemainingAccounts len:", fillRemainingAccounts.length);
  const fillIx = await svmSpokeProgram.methods
    .fillRelay(...fillRelayParams)
    .accounts(fillAccounts)
    .remainingAccounts(fillRemainingAccounts)
    .instruction();
  console.log("USER_DEBUG_OVERFLOW fillIx keys len:", fillIx.keys.length, "data len:", fillIx.data.length);

  const finalIxs = prependComputeBudgetWeb3V1([approveIx, fillIx], priorityFeePrice, fillComputeUnit);
  const finalPrograms = new Set<string>();
  const finalAccounts = new Set<string>();
  for (const ix of finalIxs) {
    finalPrograms.add(ix.programId.toBase58());
    ix.keys.forEach((k) => finalAccounts.add(k.pubkey.toBase58()));
  }
  console.log("USER_DEBUG_OVERFLOW finalIxs count:", finalIxs.length);
  console.log("USER_DEBUG_OVERFLOW final unique accounts:", finalAccounts.size);
  console.log("USER_DEBUG_OVERFLOW final programs:", Array.from(finalPrograms));
  console.log("USER_DEBUG_OVERFLOW compute budget settings:", { priorityFeePrice, fillComputeUnit });

  // Preflight compile and measure serialized size to confirm packet overflow root cause
  let preflightBytes: number | null = null;
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
      "USER_DEBUG_OVERFLOW pre-send message: staticKeys, lookupCount, lookupIdxLens, ixCount, serializedBytes",
      msgV0.staticAccountKeys?.length ?? null,
      lookups.length,
      lookups.map((l: any) => [l.writableIndexes.length, l.readonlyIndexes.length]),
      msgV0.compiledInstructions.length,
      bytes.length
    );
    if (bytes.length > 1200) preflightOverflow = true;
  } catch (e) {
    console.log("USER_DEBUG_OVERFLOW pre-send compile failed:", (e as Error).message);
    preflightOverflow = true;
  }

  try {
    // If preflight suggests overflow, fall back to local LUT creation path that packs all addresses.
    if (preflightOverflow) {
      console.log(
        "USER_DEBUG_OVERFLOW preflight suggests overflow; using local LUT creation path (no pre-provided ALTs)",
        { preflightBytes }
      );
      const txSignature = await sendTransactionWithLookupTableWeb3V1(provider.connection, finalIxs, relayer);
      console.log("Fill transaction signature:", txSignature);
      return;
    }

    // Fill using the ALT with the provided compute budget settings.
    const txSignature = await sendTransactionWithLookupTableWeb3V1(
      provider.connection,
      finalIxs,
      relayer,
      addressLookupTableAccounts
    );
    console.log("Fill transaction signature:", txSignature);
  } catch (err: any) {
    if (err instanceof RangeError || (err?.message && String(err.message).includes("encoding overruns"))) {
      console.log("USER_DEBUG_OVERFLOW caught RangeError during message compile/send; retry with local LUT path");
      try {
        const txSignature = await sendTransactionWithLookupTableWeb3V1(provider.connection, finalIxs, relayer);
        console.log("Fill transaction signature (local LUT):", txSignature);
        return;
      } catch (err2: any) {
        await logTxError(err2, "sendTransaction-localLUT");
        throw err2;
      }
    }
    await logTxError(err, "sendTransaction");
    throw err;
  }
}

acrossPlusJupiter();
