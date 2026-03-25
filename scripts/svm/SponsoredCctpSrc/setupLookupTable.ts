// This script creates ALT for a given burn token used in SVM Sponsored CCTP bridge.

import * as anchor from "@coral-xyz/anchor";
import { AnchorProvider } from "@coral-xyz/anchor";
import { TOKEN_2022_PROGRAM_ID, TOKEN_PROGRAM_ID } from "@solana/spl-token";
import {
  AddressLookupTableProgram,
  PublicKey,
  sendAndConfirmTransaction,
  SystemProgram,
  Transaction,
} from "@solana/web3.js";
import yargs from "yargs";
import { hideBin } from "yargs/helpers";
import {
  findProgramAddress,
  getMessageTransmitterV2Program,
  getSponsoredCctpSrcPeripheryProgram,
  getTokenMessengerMinterV2Program,
  isSolanaDevnet,
  SOLANA_USDC_DEVNET,
  SOLANA_USDC_MAINNET,
} from "../../../src/svm/web3-v1";

// Set up the provider and programs
const provider = AnchorProvider.env();
anchor.setProvider(provider);
const program = getSponsoredCctpSrcPeripheryProgram(provider);
const tokenMessengerMinterV2Program = getTokenMessengerMinterV2Program(provider);
const messageTransmitterV2Program = getMessageTransmitterV2Program(provider);

// Parse arguments
const argv = yargs(hideBin(process.argv)).option("burnToken", {
  type: "string",
  demandOption: false,
  default: isSolanaDevnet(provider) ? SOLANA_USDC_DEVNET : SOLANA_USDC_MAINNET,
  describe: "Burn token public key, defaults to USDC",
}).argv;

async function setupLookupTable(): Promise<void> {
  const resolvedArgv = await argv;
  const burnToken = new PublicKey(resolvedArgv.burnToken);

  const txSigner = provider.wallet.publicKey;
  const txPayer = provider.wallet.payer;
  if (!txPayer) {
    throw new Error("Provider wallet does not have a keypair");
  }

  const eventAuthority = findProgramAddress("__event_authority", program.programId).publicKey;
  const state = findProgramAddress("state", program.programId).publicKey;
  const rentFund = findProgramAddress("rent_fund", program.programId).publicKey;
  const [minimumDeposit] = PublicKey.findProgramAddressSync(
    [Buffer.from("minimum_deposit"), burnToken.toBuffer()],
    program.programId
  );
  const tokenMessengerMinterSenderAuthority = findProgramAddress(
    "sender_authority",
    tokenMessengerMinterV2Program.programId
  ).publicKey;
  const messageTransmitter = findProgramAddress("message_transmitter", messageTransmitterV2Program.programId).publicKey;
  const tokenMessenger = findProgramAddress("token_messenger", tokenMessengerMinterV2Program.programId).publicKey;
  const tokenMinter = findProgramAddress("token_minter", tokenMessengerMinterV2Program.programId).publicKey;
  const [localToken] = PublicKey.findProgramAddressSync(
    [Buffer.from("local_token"), burnToken.toBuffer()],
    tokenMessengerMinterV2Program.programId
  );
  const cctpEventAuthority = findProgramAddress("__event_authority", tokenMessengerMinterV2Program.programId).publicKey;
  const tokenProgram = (await provider.connection.getAccountInfo(burnToken))?.owner;
  if (!tokenProgram) throw new Error("Burn token owner not found");
  if (!(tokenProgram.equals(TOKEN_PROGRAM_ID) || tokenProgram.equals(TOKEN_2022_PROGRAM_ID)))
    throw new Error("Burn token is not a valid SPL token");

  const lookupAddresses = [
    state,
    burnToken,
    tokenMessengerMinterSenderAuthority,
    messageTransmitter,
    tokenMessenger,
    tokenMinter,
    localToken,
    cctpEventAuthority,
    messageTransmitterV2Program.programId,
    tokenMessengerMinterV2Program.programId,
    tokenProgram,
    SystemProgram.programId,
    eventAuthority,
    rentFund,
    minimumDeposit,
  ];

  const [lookupTableInstruction, lookupTableAddress] = AddressLookupTableProgram.createLookupTable({
    authority: txSigner,
    payer: txSigner,
    recentSlot: await provider.connection.getSlot(),
  });

  console.log(`Creating lookup table at ${lookupTableAddress}, containing addresses:`);
  console.table([
    { Property: "state", Value: state.toString() },
    { Property: "burnToken", Value: burnToken.toString() },
    { Property: "tokenMessengerMinterSenderAuthority", Value: tokenMessengerMinterSenderAuthority.toString() },
    { Property: "messageTransmitter", Value: messageTransmitter.toString() },
    { Property: "tokenMessenger", Value: tokenMessenger.toString() },
    { Property: "tokenMinter", Value: tokenMinter.toString() },
    { Property: "localToken", Value: localToken.toString() },
    { Property: "cctpEventAuthority", Value: cctpEventAuthority.toString() },
    { Property: "messageTransmitterV2ProgramId", Value: messageTransmitterV2Program.programId.toString() },
    { Property: "tokenMessengerMinterV2ProgramId", Value: tokenMessengerMinterV2Program.programId.toString() },
    { Property: "tokenProgram", Value: tokenProgram.toString() },
    { Property: "systemProgram", Value: SystemProgram.programId.toString() },
    { Property: "eventAuthority", Value: eventAuthority.toString() },
    { Property: "rentFund", Value: rentFund.toString() },
    { Property: "minimumDeposit", Value: minimumDeposit.toString() },
  ]);

  const createTx = await sendAndConfirmTransaction(
    provider.connection,
    new Transaction().add(lookupTableInstruction),
    [txPayer],
    {
      commitment: "confirmed",
      skipPreflight: true,
    }
  );
  console.log("Lookup table created successfully, transaction signature:", createTx);

  const extendInstruction = AddressLookupTableProgram.extendLookupTable({
    lookupTable: lookupTableAddress,
    authority: txSigner,
    payer: txSigner,
    addresses: lookupAddresses,
  });

  const extendTx = await sendAndConfirmTransaction(
    provider.connection,
    new Transaction().add(extendInstruction),
    [txPayer],
    {
      commitment: "confirmed",
      skipPreflight: true,
    }
  );
  console.log("Lookup table extended successfully, transaction signature:", extendTx);

  // Wait for slot to advance. ALTs only active after slot advance.
  const initialSlot = await provider.connection.getSlot();
  while ((await provider.connection.getSlot()) === initialSlot) {
    await new Promise((resolve) => setTimeout(resolve, 50));
  }

  const fetchedLookupTableAccount = (await provider.connection.getAddressLookupTable(lookupTableAddress)).value;
  if (fetchedLookupTableAccount === null) throw new Error("AddressLookupTableAccount not fetched");
}

setupLookupTable();
