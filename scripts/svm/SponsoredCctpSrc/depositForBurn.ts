// This script deposits USDC on the SVM Sponsored CCTP bridge. The script requires the quote signer keys expected to be
// used only on devnet.

import * as anchor from "@coral-xyz/anchor";
import { AnchorProvider, BN } from "@coral-xyz/anchor";
import { getAssociatedTokenAddressSync, TOKEN_PROGRAM_ID } from "@solana/spl-token";
import { Keypair, PublicKey, Transaction } from "@solana/web3.js";
import * as crypto from "crypto";
import { ethers } from "ethers";
import yargs from "yargs";
import { hideBin } from "yargs/helpers";
import {
  findProgramAddress,
  getMessageTransmitterV2Program,
  getSponsoredCctpSrcPeripheryProgram,
  getTokenMessengerMinterV2Program,
  isSolanaDevnet,
  sendTransactionWithExistingLookupTable,
  SOLANA_USDC_DEVNET,
  SOLANA_USDC_MAINNET,
} from "../../../src/svm/web3-v1";
import { requireEnv } from "../utils/helpers";

// Set up the provider and programs
const provider = AnchorProvider.env();
anchor.setProvider(provider);
const program = getSponsoredCctpSrcPeripheryProgram(provider);
const programId = program.programId;
const tokenMessengerMinterV2Program = getTokenMessengerMinterV2Program(provider);
const messageTransmitterV2Program = getMessageTransmitterV2Program(provider);

const burnToken = new PublicKey(isSolanaDevnet(provider) ? SOLANA_USDC_DEVNET : SOLANA_USDC_MAINNET);
const tokenProgram = TOKEN_PROGRAM_ID;

const sourceDomain = 5; // CCTP domain for Solana

const quoteSigner = ethers.Wallet.fromMnemonic(requireEnv("MNEMONIC"));

enum ExecutionMode {
  DirectToCore,
  ArbitraryActionsToCore,
  ArbitraryActionsToEVM,
}

// Parse arguments
const argv = yargs(hideBin(process.argv))
  .option("amount", {
    type: "number",
    demandOption: true,
    describe: "Amount to deposit in raw decimals (1 USDC = 1e6 raw decimals)",
  })
  .option("remoteDomain", {
    type: "number",
    demandOption: false,
    default: 19,
    describe: "Remote CCTP domain for the burn token, defaults to HyperEVM (19)",
  })
  .option("mintRecipient", {
    type: "string",
    demandOption: true,
    describe: "Mint recipient address, EVM format",
  })
  .option("destinationCaller", {
    type: "string",
    demandOption: true,
    describe: "Destination caller address, EVM format",
  })
  .option("finalRecipient", {
    type: "string",
    demandOption: true,
    describe: " Final recipient address, EVM format",
  })
  .option("finalToken", {
    type: "string",
    demandOption: true,
    describe: " Final token address, EVM format",
  })
  .option("maxFee", {
    type: "number",
    demandOption: false,
    describe: "Max CCTP fee in raw decimals, defaults to 1 bps from amount",
  })
  .option("minFinalityThreshold", {
    type: "number",
    demandOption: false,
    default: 1000,
    describe: "Minimum CCTP finality threshold, defaults to confirmed (1000)",
  })
  .option("maxBpsToSponsor", {
    type: "number",
    demandOption: false,
    default: 500, // 5 bps
    describe: "Maximum bps to sponsor, defaults to 500 (5 bps)",
  })
  .option("maxUserSlippageBps", {
    type: "number",
    demandOption: false,
    default: 1000, // 10 bps
    describe: "Maximum user slippage in bps, defaults to 1000 (10 bps)",
  })
  .option("executionMode", {
    type: "number",
    demandOption: false,
    default: ExecutionMode.DirectToCore,
    choices: Object.values(ExecutionMode),
    describe: "Execution mode for the sponsored CCTP flow",
  })
  .option("actionData", {
    type: "string",
    demandOption: false,
    default: "0x",
    describe: "Action data for the sponsored CCTP flow, defaults to empty bytes",
  })
  .option("deadline", {
    type: "number",
    demandOption: false,
    default: Math.floor(Date.now() / 1000) + 3600, // 1 hour from now
    describe: "Quote validity deadline, defaults to 1 hour from now",
  })
  .option("useRentClaim", { type: "boolean", default: false, describe: "Pass optional rent_claim account" })
  .option("lookupTable", {
    type: "string",
    demandOption: false,
    describe: "Address of the address lookup table to use for the transaction in case of size limitations",
  }).argv;

async function depositForBurn(): Promise<void> {
  const resolvedArgv = await argv;
  const amount = resolvedArgv.amount;
  const remoteDomain = resolvedArgv.remoteDomain;
  const mintRecipient = ethers.utils.getAddress(resolvedArgv.mintRecipient);
  const destinationCaller = ethers.utils.getAddress(resolvedArgv.destinationCaller);
  const finalRecipient = ethers.utils.getAddress(resolvedArgv.finalRecipient);
  const finalToken = ethers.utils.getAddress(resolvedArgv.finalToken);
  const maxFee = resolvedArgv.maxFee || Math.ceil(amount * 0.0001); // Default to 1 bps of the amount
  const minFinalityThreshold = resolvedArgv.minFinalityThreshold;
  const maxBpsToSponsor = resolvedArgv.maxBpsToSponsor;
  const maxUserSlippageBps = resolvedArgv.maxUserSlippageBps;
  const executionMode = Number(resolvedArgv.executionMode);
  const actionData = ethers.utils.hexlify(resolvedArgv.actionData);
  const deadline = resolvedArgv.deadline;
  const useRentClaim = resolvedArgv.useRentClaim;
  const lookupTable = resolvedArgv.lookupTable;

  const depositor = provider.wallet.payer;
  if (!depositor) {
    throw new Error("Provider wallet does not have a keypair");
  }
  const depositorTokenAccount = getAssociatedTokenAddressSync(burnToken, depositor.publicKey);

  const state = findProgramAddress("state", programId).publicKey;
  const rentFund = findProgramAddress("rent_fund", programId).publicKey;
  const [minimumDeposit] = PublicKey.findProgramAddressSync(
    [Buffer.from("minimum_deposit"), burnToken.toBuffer()],
    programId
  );
  const [denylistAccount] = PublicKey.findProgramAddressSync(
    [Buffer.from("denylist_account"), depositor.publicKey.toBuffer()],
    tokenMessengerMinterV2Program.programId
  );
  const tokenMessengerMinterSenderAuthority = findProgramAddress(
    "sender_authority",
    tokenMessengerMinterV2Program.programId
  ).publicKey;
  const messageTransmitter = findProgramAddress("message_transmitter", messageTransmitterV2Program.programId).publicKey;
  const tokenMessenger = findProgramAddress("token_messenger", tokenMessengerMinterV2Program.programId).publicKey;
  const remoteTokenMessenger = findProgramAddress("remote_token_messenger", tokenMessengerMinterV2Program.programId, [
    remoteDomain.toString(),
  ]).publicKey;
  const tokenMinter = findProgramAddress("token_minter", tokenMessengerMinterV2Program.programId).publicKey;
  const cctpEventAuthority = findProgramAddress("__event_authority", tokenMessengerMinterV2Program.programId).publicKey;
  const [localToken] = PublicKey.findProgramAddressSync(
    [Buffer.from("local_token"), burnToken.toBuffer()],
    tokenMessengerMinterV2Program.programId
  );

  const messageSentEventData = Keypair.generate();
  const nonce = crypto.randomBytes(32);
  const [usedNonce] = PublicKey.findProgramAddressSync([Buffer.from("used_nonce"), nonce], programId);

  const rentClaim = useRentClaim
    ? PublicKey.findProgramAddressSync([Buffer.from("rent_claim"), depositor.publicKey.toBuffer()], programId)[0]
    : programId;

  const quoteDataEvm = {
    sourceDomain,
    destinationDomain: remoteDomain,
    mintRecipient: ethers.utils.hexZeroPad(mintRecipient, 32),
    amount,
    burnToken: ethers.utils.hexlify(burnToken.toBuffer()),
    destinationCaller: ethers.utils.hexZeroPad(destinationCaller, 32),
    maxFee,
    minFinalityThreshold,
    nonce: ethers.utils.hexlify(nonce),
    deadline,
    maxBpsToSponsor,
    maxUserSlippageBps,
    finalRecipient: ethers.utils.hexZeroPad(finalRecipient, 32),
    finalToken: ethers.utils.hexZeroPad(finalToken, 32),
    executionMode,
    actionData,
  };

  // Hash the quote data for EVM signing
  const hash1 = ethers.utils.keccak256(
    ethers.utils.defaultAbiCoder.encode(
      ["uint32", "uint32", "bytes32", "uint256", "bytes32", "bytes32", "uint256", "uint32"],
      [
        quoteDataEvm.sourceDomain,
        quoteDataEvm.destinationDomain,
        quoteDataEvm.mintRecipient,
        quoteDataEvm.amount,
        quoteDataEvm.burnToken,
        quoteDataEvm.destinationCaller,
        quoteDataEvm.maxFee,
        quoteDataEvm.minFinalityThreshold,
      ]
    )
  );
  const hash2 = ethers.utils.keccak256(
    ethers.utils.defaultAbiCoder.encode(
      ["bytes32", "uint256", "uint256", "uint256", "bytes32", "bytes32", "uint8", "bytes32"],
      [
        quoteDataEvm.nonce,
        quoteDataEvm.deadline,
        quoteDataEvm.maxBpsToSponsor,
        quoteDataEvm.maxUserSlippageBps,
        quoteDataEvm.finalRecipient,
        quoteDataEvm.finalToken,
        quoteDataEvm.executionMode,
        ethers.utils.keccak256(quoteDataEvm.actionData),
      ]
    )
  );
  const typedDataHash = ethers.utils.keccak256(
    ethers.utils.defaultAbiCoder.encode(["bytes32", "bytes32"], [hash1, hash2])
  );
  const signature = Array.from(
    Buffer.from(ethers.utils.arrayify(ethers.utils.joinSignature(quoteSigner._signingKey().signDigest(typedDataHash))))
  );

  // Encode quote for Solana
  const quote = {
    sourceDomain: quoteDataEvm.sourceDomain,
    destinationDomain: quoteDataEvm.destinationDomain,
    mintRecipient: new PublicKey(ethers.utils.arrayify(quoteDataEvm.mintRecipient)),
    amount: new BN(quoteDataEvm.amount.toString()),
    burnToken: new PublicKey(ethers.utils.arrayify(quoteDataEvm.burnToken)),
    destinationCaller: new PublicKey(ethers.utils.arrayify(quoteDataEvm.destinationCaller)),
    maxFee: new BN(quoteDataEvm.maxFee.toString()),
    minFinalityThreshold: quoteDataEvm.minFinalityThreshold,
    nonce: Array.from(ethers.utils.arrayify(quoteDataEvm.nonce)),
    deadline: new BN(quoteDataEvm.deadline.toString()),
    maxBpsToSponsor: new BN(quoteDataEvm.maxBpsToSponsor.toString()),
    maxUserSlippageBps: new BN(quoteDataEvm.maxUserSlippageBps.toString()),
    finalRecipient: new PublicKey(ethers.utils.arrayify(quoteDataEvm.finalRecipient)),
    finalToken: new PublicKey(ethers.utils.arrayify(quoteDataEvm.finalToken)),
    executionMode: quoteDataEvm.executionMode,
    actionData: Buffer.from(ethers.utils.arrayify(quoteDataEvm.actionData)),
  };

  const depositAccounts = {
    signer: depositor.publicKey,
    payer: depositor.publicKey,
    state,
    rentFund,
    minimumDeposit,
    usedNonce,
    rentClaim,
    depositorTokenAccount,
    burnToken,
    denylistAccount,
    tokenMessengerMinterSenderAuthority,
    messageTransmitter,
    tokenMessenger,
    remoteTokenMessenger,
    tokenMinter,
    localToken,
    cctpEventAuthority,
    tokenProgram,
    messageSentEventData: messageSentEventData.publicKey,
    program: programId,
  };
  const ix = await program.methods.depositForBurn({ quote, signature }).accounts(depositAccounts).instruction();

  console.log("Depositing on sponsored CCTP bridge...");
  console.table([
    { Property: "programId", Value: programId.toString() },
    { Property: "amount", Value: amount.toString() },
    { Property: "remoteDomain", Value: remoteDomain.toString() },
    { Property: "mintRecipient", Value: mintRecipient },
    { Property: "destinationCaller", Value: destinationCaller },
    { Property: "finalRecipient", Value: finalRecipient },
    { Property: "finalToken", Value: finalToken },
    { Property: "maxFee", Value: maxFee.toString() },
    { Property: "minFinalityThreshold", Value: minFinalityThreshold.toString() },
    { Property: "maxBpsToSponsor", Value: maxBpsToSponsor.toString() },
    { Property: "maxUserSlippageBps", Value: maxUserSlippageBps.toString() },
    { Property: "executionMode", Value: executionMode.toString() },
    { Property: "actionData", Value: actionData },
    { Property: "depositorTokenAccount", Value: depositorTokenAccount.toString() },
    { Property: "depositor", Value: depositor.publicKey.toString() },
    { Property: "state", Value: state.toString() },
    { Property: "rentFund", Value: rentFund.toString() },
    { Property: "minimumDeposit", Value: minimumDeposit.toString() },
    { Property: "usedNonce", Value: usedNonce.toString() },
    { Property: "rentClaim", Value: rentClaim.toString() },
    { Property: "burnToken", Value: burnToken.toString() },
    { Property: "depositorTokenAccount", Value: depositorTokenAccount.toString() },
    { Property: "denylistAccount", Value: denylistAccount.toString() },
    { Property: "tokenMessengerMinterSenderAuthority", Value: tokenMessengerMinterSenderAuthority.toString() },
    { Property: "messageTransmitter", Value: messageTransmitter.toString() },
    { Property: "tokenMessenger", Value: tokenMessenger.toString() },
    { Property: "remoteTokenMessenger", Value: remoteTokenMessenger.toString() },
    { Property: "tokenMinter", Value: tokenMinter.toString() },
    { Property: "localToken", Value: localToken.toString() },
    { Property: "cctpEventAuthority", Value: cctpEventAuthority.toString() },
    { Property: "messageSentEventData", Value: messageSentEventData.publicKey.toString() },
  ]);

  const tx = new Transaction().add(ix);
  try {
    const txSignature = await provider.sendAndConfirm(tx, [depositor, messageSentEventData], {
      commitment: "confirmed",
    });
    console.log("Deposited to the sponsored CCTP bridge successfully, transaction signature:", txSignature);
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    if (/Transaction too large/i.test(msg)) {
      if (!lookupTable) {
        throw new Error(
          "Transaction too large, please provide an address lookup table using the --lookupTable option."
        );
      }

      console.log("Transaction too large, retrying with address lookup table...");

      const lookupTableAccount = (await provider.connection.getAddressLookupTable(new PublicKey(lookupTable))).value;
      if (lookupTableAccount === null) throw new Error("AddressLookupTableAccount not fetched");

      const txSignature = await sendTransactionWithExistingLookupTable(
        provider.connection,
        [ix],
        lookupTableAccount,
        depositor,
        [messageSentEventData]
      );
      console.log("Deposited to the sponsored CCTP bridge successfully, transaction signature:", txSignature);
    } else {
      throw err;
    }
  }
}

depositForBurn();
