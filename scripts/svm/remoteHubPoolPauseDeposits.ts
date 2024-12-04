// This script bridges remote call to pause deposits on Solana Spoke Pool. Required environment:
// - ETHERS_PROVIDER_URL: Ethereum RPC provider URL.
// - ETHERS_MNEMONIC: Mnemonic of the wallet that will sign the sending transaction on Ethereum
// - HUB_POOL_ADDRESS: Hub Pool address

import * as anchor from "@coral-xyz/anchor";
import { AnchorProvider, BN, Program, web3 } from "@coral-xyz/anchor";
import { AccountMeta, PublicKey } from "@solana/web3.js";
import "dotenv/config";
import { ethers } from "ethers";
import yargs from "yargs";
import { hideBin } from "yargs/helpers";
import { MessageTransmitter } from "../../target/types/message_transmitter";
import { SvmSpoke } from "../../target/types/svm_spoke";
import { decodeMessageHeader, getMessages } from "../../test/svm/cctpHelpers";
import { HubPool__factory } from "../../typechain";
import { CIRCLE_IRIS_API_URL_DEVNET, CIRCLE_IRIS_API_URL_MAINNET } from "./utils/constants";

// Set up Solana provider.
const provider = AnchorProvider.env();
anchor.setProvider(provider);

// Parse arguments
const argv = yargs(hideBin(process.argv))
  .option("chainId", { type: "string", demandOption: true, describe: "Chain ID" })
  .option("pause", { type: "boolean", demandOption: true, describe: "Pause deposits" })
  .option("resumeRemoteTx", { type: "string", demandOption: false, describe: "Resume receiving remote tx" }).argv;

async function remoteHubPoolPauseDeposit(): Promise<void> {
  const resolvedArgv = await argv;

  const chainId = resolvedArgv.chainId;
  const seed = new BN(0);
  const resumeRemoteTx = resolvedArgv.resumeRemoteTx;
  const pause = resolvedArgv.pause;

  // Set up Ethereum provider.
  if (!process.env.ETHERS_PROVIDER_URL) {
    throw new Error("Environment variable ETHERS_PROVIDER_URL is not set");
  }
  const ethersProvider = new ethers.providers.JsonRpcProvider(process.env.ETHERS_PROVIDER_URL);
  if (!process.env.ETHERS_MNEMONIC) {
    throw new Error("Environment variable ETHERS_MNEMONIC is not set");
  }
  const ethersSigner = ethers.Wallet.fromMnemonic(process.env.ETHERS_MNEMONIC).connect(ethersProvider);

  if (!process.env.HUB_POOL_ADDRESS) {
    throw new Error("Environment variable HUB_POOL_ADDRESS is not set");
  }
  const hubPoolAddress = process.env.HUB_POOL_ADDRESS;

  let cluster: "devnet" | "mainnet";
  const rpcEndpoint = provider.connection.rpcEndpoint;
  if (rpcEndpoint.includes("devnet")) cluster = "devnet";
  else if (rpcEndpoint.includes("mainnet")) cluster = "mainnet";
  else throw new Error(`Unsupported cluster endpoint: ${rpcEndpoint}`);
  const isDevnet = cluster == "devnet";

  // CCTP domains.
  const remoteDomain = 0; // Ethereum

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

  const irisApiUrl = isDevnet ? CIRCLE_IRIS_API_URL_DEVNET : CIRCLE_IRIS_API_URL_MAINNET;

  const hubPool = HubPool__factory.connect(hubPoolAddress, ethersProvider);
  const spokePoolIface = new ethers.utils.Interface(["function pauseDeposits(bool pause)"]);

  console.log("Remotely configuring deposit route...");
  console.table([
    { Property: "seed", Value: seed.toString() },
    { Property: "chainId", Value: (chainId as any).toString() },
    { Property: "pause", Value: pause },
    { Property: "svmSpokeProgramProgramId", Value: svmSpokeProgram.programId.toString() },
    { Property: "providerPublicKey", Value: provider.wallet.publicKey.toString() },
    { Property: "statePda", Value: statePda.toString() },
    { Property: "messageTransmitterProgramId", Value: messageTransmitterProgram.programId.toString() },
    { Property: "messageTransmitterState", Value: messageTransmitterState.toString() },
    { Property: "authorityPda", Value: authorityPda.toString() },
    { Property: "selfAuthority", Value: selfAuthority.toString() },
    { Property: "eventAuthority", Value: eventAuthority.toString() },
    { Property: "remoteSender", Value: ethersSigner.address },
  ]);

  // Send pauseDeposits call from Ethereum, unless resuming a remote transaction.
  let remoteTxHash: string;
  if (!resumeRemoteTx) {
    console.log("Sending pauseDeposits message from HubPool...");
    const calldata = spokePoolIface.encodeFunctionData("pauseDeposits", [pause]);
    const tx = await hubPool.connect(ethersSigner).relaySpokePoolAdminFunction(chainId, calldata);
    await tx.wait();
    remoteTxHash = tx.hash;
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

  // state
  remainingAccounts.push({
    isSigner: false,
    isWritable: true,
    pubkey: statePda,
  });

  // event_authority in self-invoked CPIs (appended by Anchor with event_cpi macro).
  remainingAccounts.push({
    isSigner: false,
    isWritable: true,
    pubkey: eventAuthority,
  });
  // program
  remainingAccounts.push({
    isSigner: false,
    isWritable: true,
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

  let stateAccount = await svmSpokeProgram.account.state.fetch(statePda);
  console.log("Updated deposit route state to: pausedDeposits =", stateAccount.pausedDeposits);
}

remoteHubPoolPauseDeposit()
  .then(() => {
    process.exit(0);
  })
  .catch((err) => {
    console.error(err);
    process.exit(1);
  });
