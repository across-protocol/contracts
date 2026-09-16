// Send a tokenless CCTP V2 pause/resume message from the configured EVM admin, or finish an existing transaction.
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
  evmAddressToPublicKey,
  getSpokePoolProgram,
  isSolanaDevnet,
  MAINNET_CCTP_V2_MESSAGE_TRANSMITTER_ADDRESS,
  SEPOLIA_CCTP_V2_MESSAGE_TRANSMITTER_ADDRESS,
} from "../../src/svm/web3-v1";
import { CHAIN_IDs, getNodeUrl } from "../../utils";
import { requireEnv } from "./utils/helpers";
import { finalizeCctpV2Messages } from "./utils/cctpV2";

async function remotePauseDeposits(): Promise<void> {
  const args = await yargs(hideBin(process.argv))
    .option("seed", { type: "string", default: "0", describe: "Spoke state PDA seed" })
    .option("pause", { type: "boolean", describe: "Pause or resume deposits" })
    .option("resumeRemoteTx", { type: "string", describe: "Resume receiving an EVM source transaction" })
    .check((args) => {
      if ((args.pause === undefined) === (args.resumeRemoteTx === undefined))
        throw new Error("Specify exactly one of --pause or --resumeRemoteTx");
      return true;
    })
    .strict()
    .parse();
  const provider = AnchorProvider.env();
  const isDevnet = isSolanaDevnet(provider);
  const program = getSpokePoolProgram(provider);
  const [statePda] = PublicKey.findProgramAddressSync(
    [Buffer.from("state"), new BN(args.seed).toArrayLike(Buffer, "le", 8)],
    program.programId
  );
  const state = await program.account.state.fetch(statePda);
  let remoteTxHash = args.resumeRemoteTx;
  if (!remoteTxHash) {
    const chainId = isDevnet ? CHAIN_IDs.SEPOLIA : CHAIN_IDs.MAINNET;
    const evmProvider = new ethers.providers.JsonRpcProvider(getNodeUrl(chainId));
    if ((await evmProvider.getNetwork()).chainId !== chainId)
      throw new Error("Ethereum RPC does not match the Solana cluster");
    const signer = ethers.Wallet.fromMnemonic(requireEnv("MNEMONIC")).connect(evmProvider);
    if (state.remoteDomain !== 0 || !state.crossDomainAdmin.equals(evmAddressToPublicKey(signer.address)))
      throw new Error("Wallet is not the spoke's Ethereum admin; use remoteHubPoolPauseDeposits for HubPool ownership");
    const transmitter = new ethers.Contract(
      isDevnet ? SEPOLIA_CCTP_V2_MESSAGE_TRANSMITTER_ADDRESS : MAINNET_CCTP_V2_MESSAGE_TRANSMITTER_ADDRESS,
      [
        "function sendMessage(uint32 destinationDomain, bytes32 recipient, bytes32 destinationCaller, uint32 minFinalityThreshold, bytes messageBody)",
      ],
      signer
    );
    const calldata = new ethers.utils.Interface(["function pauseDeposits(bool pause)"]).encodeFunctionData(
      "pauseDeposits",
      [args.pause]
    );
    const tx = await transmitter.sendMessage(
      5,
      program.programId.toBytes(),
      ethers.constants.HashZero,
      CCTP_FINALITY_THRESHOLD_FINALIZED,
      calldata
    );
    // Print before waiting so a dropped connection can be recovered with --resumeRemoteTx.
    remoteTxHash = tx.hash;
    console.log("Source transaction:", remoteTxHash);
    await tx.wait();
  }
  await finalizeCctpV2Messages(
    provider,
    program,
    statePda,
    remoteTxHash!,
    state.remoteDomain,
    isDevnet ? CIRCLE_IRIS_API_URL_DEVNET : CIRCLE_IRIS_API_URL_MAINNET
  );
  console.log("pausedDeposits:", (await program.account.state.fetch(statePda)).pausedDeposits);
}

remotePauseDeposits().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
