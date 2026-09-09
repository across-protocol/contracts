// This script bridges remote call to pause deposits on Solana Spoke Pool via the HubPool over CCTP V2. Required
// environment:
// - NODE_URL_${CHAIN_ID}: Ethereum RPC URL (must point to the Mainnet or Sepolia depending on Solana cluster).
// - MNEMONIC: Mnemonic of the wallet that will sign the sending transaction on Ethereum
// - HUB_POOL_ADDRESS: Hub Pool address

import * as anchor from "@coral-xyz/anchor";
import { AnchorProvider, BN } from "@coral-xyz/anchor";
import { PublicKey } from "@solana/web3.js";
import "dotenv/config";
import { ethers } from "ethers";
import yargs from "yargs";
import { hideBin } from "yargs/helpers";
import {
  CIRCLE_IRIS_API_URL_DEVNET,
  CIRCLE_IRIS_API_URL_MAINNET,
  getSpokePoolProgram,
  getV2Messages,
  isSolanaDevnet,
} from "../../src/svm/web3-v1";
import { CHAIN_IDs, getNodeUrl } from "../../utils";
import { getHubPoolContract, receiveCctpV2MessageOnSpoke, requireEnv } from "./utils/helpers";

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

  // Set up Ethereum provider and signer.
  const isDevnet = isSolanaDevnet(provider);
  const nodeURL = getNodeUrl(isDevnet ? CHAIN_IDs.SEPOLIA : CHAIN_IDs.MAINNET);
  const ethersProvider = new ethers.providers.JsonRpcProvider(nodeURL);
  const ethersSigner = ethers.Wallet.fromMnemonic(requireEnv("MNEMONIC")).connect(ethersProvider);

  const hubPoolAddress = requireEnv("HUB_POOL_ADDRESS");

  // CCTP domains.
  const remoteDomain = 0; // Ethereum

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

  const irisApiUrl = isDevnet ? CIRCLE_IRIS_API_URL_DEVNET : CIRCLE_IRIS_API_URL_MAINNET;

  const hubPool = getHubPoolContract(hubPoolAddress, ethersProvider);
  const spokePoolIface = new ethers.utils.Interface(["function pauseDeposits(bool pause)"]);

  console.log("Remotely pausing deposits...");
  console.table([
    { Property: "seed", Value: seed.toString() },
    { Property: "chainId", Value: (chainId as any).toString() },
    { Property: "pause", Value: pause },
    { Property: "svmSpokeProgramProgramId", Value: svmSpokeProgram.programId.toString() },
    { Property: "providerPublicKey", Value: provider.wallet.publicKey.toString() },
    { Property: "statePda", Value: statePda.toString() },
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

  let stateAccount = await svmSpokeProgram.account.state.fetch(statePda);
  console.log("Updated deposit state to: pausedDeposits =", stateAccount.pausedDeposits);
}

remoteHubPoolPauseDeposit()
  .then(() => {
    process.exit(0);
  })
  .catch((err) => {
    console.error(err);
    process.exit(1);
  });
