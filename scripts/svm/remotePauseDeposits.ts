// This script bridges remote call to pause deposits on Solana Spoke Pool. Required environment:
// - NODE_URL_${CHAIN_ID}: Ethereum RPC URL (must point to the Mainnet or Sepolia depending on Solana cluster).
// - MNEMONIC: Mnemonic of the wallet that will sign the sending transaction on Ethereum

import "dotenv/config";
import * as anchor from "@coral-xyz/anchor";
import { BN, Program, AnchorProvider, web3 } from "@coral-xyz/anchor";
import { AccountMeta, PublicKey } from "@solana/web3.js";
import { SvmSpoke } from "../../target/types/svm_spoke";
import yargs from "yargs";
import { hideBin } from "yargs/helpers";
import { ethers } from "ethers";
import { getNodeUrl } from "@uma/common";
import { MessageTransmitter } from "../../target/types/message_transmitter";
import { decodeMessageHeader, getMessages } from "../../test/svm/cctpHelpers";
import { isSolanaDevnet, requireEnv } from "./utils/helpers";
import {
  CIRCLE_IRIS_API_URL_DEVNET,
  CIRCLE_IRIS_API_URL_MAINNET,
  MAINNET_CCTP_MESSAGE_TRANSMITTER_ADDRESS,
  SEPOLIA_CCTP_MESSAGE_TRANSMITTER_ADDRESS,
} from "./utils/constants";
import { CHAIN_IDs } from "../../utils/constants";

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
  const nodeURL = isDevnet ? getNodeUrl("sepolia", true) : getNodeUrl("mainnet", true);
  const ethersProvider = new ethers.providers.JsonRpcProvider(nodeURL);
  const ethersSigner = ethers.Wallet.fromMnemonic(requireEnv("MNEMONIC")).connect(ethersProvider);

  // CCTP domains.
  const remoteDomain = 0; // Ethereum
  const localDomain = 5; // Solana

  // Get Solana programs and accounts.
  const svmSpokeIdl = require("../../target/idl/svm_spoke.json");
  const svmSpokeProgram = new Program<SvmSpoke>(svmSpokeIdl, provider);
  const [statePda, _] = PublicKey.findProgramAddressSync(
    [Buffer.from("state"), seed.toArrayLike(Buffer, "le", 8)],
    svmSpokeProgram.programId
  );
  const messageTransmitterIdl = require("../../target/idl/message_transmitter.json");
  const messageTransmitterProgram = new Program<MessageTransmitter>(messageTransmitterIdl, provider);
  const [messageTransmitterState] = PublicKey.findProgramAddressSync(
    [Buffer.from("message_transmitter")],
    messageTransmitterProgram.programId
  );
  const [authorityPda] = PublicKey.findProgramAddressSync(
    [Buffer.from("message_transmitter_authority"), svmSpokeProgram.programId.toBuffer()],
    messageTransmitterProgram.programId
  );
  const [selfAuthority] = PublicKey.findProgramAddressSync([Buffer.from("self_authority")], svmSpokeProgram.programId);
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
    "function sendMessage(uint32 destinationDomain, bytes32 recipient, bytes messageBody)",
    "event MessageSent(bytes message)",
  ]);

  // CCTP MessageTransmitter from https://developers.circle.com/stablecoins/docs/evm-smart-contracts
  const messageTransmitterRemoteAddress = isDevnet
    ? SEPOLIA_CCTP_MESSAGE_TRANSMITTER_ADDRESS
    : MAINNET_CCTP_MESSAGE_TRANSMITTER_ADDRESS;

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
    { Property: "messageTransmitterProgramId", Value: messageTransmitterProgram.programId.toString() },
    { Property: "messageTransmitterState", Value: messageTransmitterState.toString() },
    { Property: "authorityPda", Value: authorityPda.toString() },
    { Property: "selfAuthority", Value: selfAuthority.toString() },
    { Property: "eventAuthority", Value: eventAuthority.toString() },
    { Property: "messageTransmitterRemoteAddress", Value: messageTransmitterRemoteAddress },
    { Property: "remoteSender", Value: ethersSigner.address },
  ]);

  // Send pauseDeposits call from Ethereum, unless resuming a remote transaction.
  let remoteTxHash: string;
  if (!resumeRemoteTx) {
    console.log("Sending pauseDeposits message from remote domain...");
    const calldata = spokePoolIface.encodeFunctionData("pauseDeposits", [pause]);
    const sendTx = await messageTransmitterRemote.sendMessage.send(
      localDomain,
      svmSpokeProgram.programId.toBytes(),
      calldata
    );
    await sendTx.wait();
    remoteTxHash = sendTx.hash;
    console.log("Message sent on remote chain, tx", remoteTxHash);
  } else remoteTxHash = resumeRemoteTx;

  // Fetch attestation from CCTP attestation service.
  const attestationResponse = await getMessages(remoteTxHash, remoteDomain, irisApiUrl);
  const { attestation, message } = attestationResponse.messages[0];
  console.log("CCTP attestation response:", attestationResponse.messages[0]);

  // Accounts in CCTP message_transmitter receive_message instruction.
  const nonce = decodeMessageHeader(Buffer.from(message.replace("0x", ""), "hex")).nonce;
  const usedNonces = (await messageTransmitterProgram.methods
    .getNoncePda({
      nonce: new BN(nonce.toString()),
      sourceDomain: remoteDomain,
    })
    .accounts({
      messageTransmitter: messageTransmitterState,
    })
    .view()) as PublicKey;
  const receiveMessageAccounts = {
    payer: provider.wallet.publicKey,
    caller: provider.wallet.publicKey,
    authorityPda,
    messageTransmitter: messageTransmitterState,
    usedNonces,
    receiver: svmSpokeProgram.programId,
    systemProgram: web3.SystemProgram.programId,
  };

  // accountMetas list to pass to remaining accounts when receiving message via CCTP.
  const remainingAccounts: AccountMeta[] = [];
  // state in HandleReceiveMessage accounts (used for remote domain and sender authentication).
  remainingAccounts.push({
    isSigner: false,
    isWritable: false,
    pubkey: statePda,
  });
  // self_authority in HandleReceiveMessage accounts, also signer in self-invoked CPIs.
  remainingAccounts.push({
    isSigner: false,
    isWritable: false,
    pubkey: selfAuthority,
  });
  // program in HandleReceiveMessage accounts.
  remainingAccounts.push({
    isSigner: false,
    isWritable: false,
    pubkey: svmSpokeProgram.programId,
  });
  // state in self-invoked CPIs (state can change as a result of remote call).
  remainingAccounts.push({
    isSigner: false,
    isWritable: true,
    pubkey: statePda,
  });
  // event_authority in self-invoked CPIs (appended by Anchor with event_cpi macro).
  remainingAccounts.push({
    isSigner: false,
    isWritable: false,
    pubkey: eventAuthority,
  });
  // program in self-invoked CPIs (appended by Anchor with event_cpi macro).
  remainingAccounts.push({
    isSigner: false,
    isWritable: false,
    pubkey: svmSpokeProgram.programId,
  });

  // Receive remote message on Solana.
  console.log("Receiving message on Solana...");
  const receiveMessageTx = await messageTransmitterProgram.methods
    .receiveMessage({
      message: Buffer.from(message.replace("0x", ""), "hex"),
      attestation: Buffer.from(attestation.replace("0x", ""), "hex"),
    })
    .accounts(receiveMessageAccounts as any)
    .remainingAccounts(remainingAccounts)
    .rpc();
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
