// Send a tokenless CCTP V2 pause/resume message through HubPool, or finish an existing transaction.
import { AnchorProvider, BN } from "@coral-xyz/anchor";
import { PublicKey } from "@solana/web3.js";
import "dotenv/config";
import { ethers } from "ethers";
import yargs from "yargs";
import { hideBin } from "yargs/helpers";
import {
  CIRCLE_IRIS_API_URL_DEVNET,
  CIRCLE_IRIS_API_URL_MAINNET,
  evmAddressToPublicKey,
  getSpokePoolProgram,
  isSolanaDevnet,
} from "../../src/svm/web3-v1";
import { CHAIN_IDs, getNodeUrl } from "../../utils";
import { getHubPoolContract, requireEnv } from "./utils/helpers";
import { finalizeCctpV2Messages } from "./utils/cctpV2";

async function remoteHubPoolPauseDeposits(): Promise<void> {
  const args = await yargs(hideBin(process.argv))
    .option("chainId", { type: "string", demandOption: true, describe: "Solana spoke chain ID" })
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
    [Buffer.from("state"), new BN(0).toArrayLike(Buffer, "le", 8)],
    program.programId
  );
  const state = await program.account.state.fetch(statePda);
  if (state.chainId.toString() !== args.chainId) throw new Error("Chain ID does not match the Solana spoke");
  let remoteTxHash = args.resumeRemoteTx;
  if (!remoteTxHash) {
    const chainId = isDevnet ? CHAIN_IDs.SEPOLIA : CHAIN_IDs.MAINNET;
    const evmProvider = new ethers.providers.JsonRpcProvider(getNodeUrl(chainId));
    if ((await evmProvider.getNetwork()).chainId !== chainId)
      throw new Error("Ethereum RPC does not match the Solana cluster");
    const signer = ethers.Wallet.fromMnemonic(requireEnv("MNEMONIC")).connect(evmProvider);
    const hubPool = getHubPoolContract(ethers.utils.getAddress(requireEnv("HUB_POOL_ADDRESS")), signer);
    if (state.remoteDomain !== 0 || !state.crossDomainAdmin.equals(evmAddressToPublicKey(hubPool.address)))
      throw new Error("HubPool is not the spoke's Ethereum admin");
    const calldata = new ethers.utils.Interface(["function pauseDeposits(bool pause)"]).encodeFunctionData(
      "pauseDeposits",
      [args.pause]
    );
    const tx = await hubPool.relaySpokePoolAdminFunction(args.chainId, calldata);
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

remoteHubPoolPauseDeposits().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
