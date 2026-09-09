// This script bridges remote call to pause deposits on Solana Spoke Pool over CCTP V2. Required environment:
// - NODE_URL_${CHAIN_ID}: Ethereum RPC URL (must point to the Mainnet or Sepolia depending on Solana cluster).
// - MNEMONIC: Mnemonic of the wallet that will sign the sending transaction on Ethereum

import * as anchor from "@coral-xyz/anchor";
import { AnchorProvider, BN } from "@coral-xyz/anchor";
import { PublicKey } from "@solana/web3.js";
import "dotenv/config";
import { ethers } from "ethers";
import yargs from "yargs";
import { hideBin } from "yargs/helpers";
import {
  CCTP_FINALITY_THRESHOLD_FINALIZED,
  CIRCLE_IRIS_API_URL_DEVNET,
  CIRCLE_IRIS_API_URL_MAINNET,
  getSpokePoolProgram,
  getV2Messages,
  isSolanaDevnet,
  MAINNET_CCTP_V2_MESSAGE_TRANSMITTER_ADDRESS,
  SEPOLIA_CCTP_V2_MESSAGE_TRANSMITTER_ADDRESS,
} from "../../src/svm/web3-v1";
import { CHAIN_IDs, getNodeUrl } from "../../utils";
import { receiveCctpV2MessageOnSpoke, requireEnv } from "./utils/helpers";

// Set up Solana provider.
const provider = AnchorProvider.env();
anchor.setProvider(provider);

// Parse arguments
const argv = yargs(hideBin(process.argv))
  .option("seed", { type: "string", demandOption: true, describe: "Seed for the state account PDA" })
  .option("pause", { type: "boolean", demandOption: false, describe: "Enable or disable deposits" })
  .option("resumeRemoteTx", { type: "string", demandOption: false, describe: "Resume receiving remote tx" })
  .check((argv) => {
    if (argv.pause !== undefined && argv.resumeRemoteTx !== undefined) {
      throw new Error("Options --pause and --resumeRemoteTx are mutually exclusive");
    }
    if (argv.pause === undefined && argv.resumeRemoteTx === undefined) {
      throw new Error("One of the options --pause or --resumeRemoteTx is required");
    }
    return true;
  }).argv;

async function remotePauseDeposits(): Promise<void> {
  const resolvedArgv = await argv;
  const seed = new BN(resolvedArgv.seed);
  const pause = resolvedArgv.pause;
  const resumeRemoteTx = resolvedArgv.resumeRemoteTx;

  // Set up Ethereum provider and signer.
  const isDevnet = isSolanaDevnet(provider);
  const nodeURL = getNodeUrl(isDevnet ? CHAIN_IDs.SEPOLIA : CHAIN_IDs.MAINNET);
  const ethersProvider = new ethers.providers.JsonRpcProvider(nodeURL);
  const ethersSigner = ethers.Wallet.fromMnemonic(requireEnv("MNEMONIC")).connect(ethersProvider);

  // CCTP domains.
  const remoteDomain = 0; // Ethereum
  const localDomain = 5; // Solana

  // Get Solana programs and accounts.
  const svmSpokeProgram = getSpokePoolProgram(provider);
  const [statePda, _] = PublicKey.findProgramAddressSync(
    [Buffer.from("state"), seed.toArrayLike(Buffer, "le", 8)],
    svmSpokeProgram.programId
  );
  const [eventAuthority] = PublicKey.findProgramAddressSync(
    [Buffer.from("__event_authority")],
    svmSpokeProgram.programId
  );

  const solanaCluster = isDevnet ? "devnet" : "mainnet";
  const irisApiUrl = isDevnet ? CIRCLE_IRIS_API_URL_DEVNET : CIRCLE_IRIS_API_URL_MAINNET;
  const supportedEvmChainId = isDevnet ? CHAIN_IDs.SEPOLIA : CHAIN_IDs.MAINNET; // Sepolia is bridged to devnet, Ethereum to mainnet in CCTP.
  const evmChainId = (await ethersProvider.getNetwork()).chainId;
  if (evmChainId !== supportedEvmChainId) {
    throw new Error(`Chain ID ${evmChainId} does not match expected Solana cluster ${solanaCluster}`);
  }

  const messageTransmitterRemoteIface = new ethers.utils.Interface([
    "function sendMessage(uint32 destinationDomain, bytes32 recipient, bytes32 destinationCaller, uint32 minFinalityThreshold, bytes messageBody)",
    "event MessageSent(bytes message)",
  ]);

  // CCTP V2 MessageTransmitter from https://developers.circle.com/cctp/evm-smart-contracts
  const messageTransmitterRemoteAddress = isDevnet
    ? SEPOLIA_CCTP_V2_MESSAGE_TRANSMITTER_ADDRESS
    : MAINNET_CCTP_V2_MESSAGE_TRANSMITTER_ADDRESS;

  const messageTransmitterRemote = new ethers.Contract(
    messageTransmitterRemoteAddress,
    messageTransmitterRemoteIface,
    ethersSigner
  );

  const spokePoolIface = new ethers.utils.Interface(["function pauseDeposits(bool pause)"]);

  console.log("Remotely controlling pausedDeposits...");
  console.table([
    { Property: "seed", Value: seed.toString() },
    { Property: "evmChainId", Value: evmChainId.toString() },
    { Property: "pause", Value: pause },
    { Property: "svmSpokeProgramProgramId", Value: svmSpokeProgram.programId.toString() },
    { Property: "providerPublicKey", Value: provider.wallet.publicKey.toString() },
    { Property: "statePda", Value: statePda.toString() },
    { Property: "eventAuthority", Value: eventAuthority.toString() },
    { Property: "messageTransmitterRemoteAddress", Value: messageTransmitterRemoteAddress },
    { Property: "remoteSender", Value: ethersSigner.address },
  ]);

  // Send pauseDeposits call from Ethereum, unless resuming a remote transaction.
  let remoteTxHash: string;
  if (!resumeRemoteTx) {
    console.log("Sending pauseDeposits message from remote domain...");
    const calldata = spokePoolIface.encodeFunctionData("pauseDeposits", [pause]);
    // Anyone may relay the attested message on Solana and the spoke only accepts finalized messages.
    const sendTx = await messageTransmitterRemote.sendMessage(
      localDomain,
      svmSpokeProgram.programId.toBytes(),
      ethers.constants.HashZero,
      CCTP_FINALITY_THRESHOLD_FINALIZED,
      calldata
    );
    await sendTx.wait();
    remoteTxHash = sendTx.hash;
    console.log("Message sent on remote chain, tx", remoteTxHash);
  } else remoteTxHash = resumeRemoteTx;

  // Fetch attestation from CCTP attestation service.
  const [{ attestation, message }] = await getV2Messages(remoteTxHash, remoteDomain, irisApiUrl);
  console.log("CCTP attestation response:", {
    message: message.toString("hex"),
    attestation: attestation.toString("hex"),
  });

  // Receive remote message on Solana. Remaining accounts are for the self-invoked pause_deposits instruction.
  console.log("Receiving message on Solana...");
  const receiveMessageTx = await receiveCctpV2MessageOnSpoke(
    provider,
    svmSpokeProgram,
    statePda,
    message,
    attestation,
    [
      { isSigner: false, isWritable: true, pubkey: statePda },
      // event_authority and program in self-invoked CPIs (appended by Anchor with event_cpi macro).
      { isSigner: false, isWritable: false, pubkey: eventAuthority },
      { isSigner: false, isWritable: false, pubkey: svmSpokeProgram.programId },
    ]
  );
  console.log("\nReceived remote message");
  console.log("Your transaction signature", receiveMessageTx);

  // Check updated state.
  const stateData = await svmSpokeProgram.account.state.fetch(statePda);
  console.log("Updated pausedDeposits state to:", stateData.pausedDeposits);
}

remotePauseDeposits()
  .then(() => {
    process.exit(0);
  })
  .catch((err) => {
    console.error(err);
    process.exit(1);
  });
