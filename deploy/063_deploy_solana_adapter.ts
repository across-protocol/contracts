import { utils } from "@coral-xyz/anchor";
import { DeployFunction } from "hardhat-deploy/types";
import { HardhatRuntimeEnvironment } from "hardhat/types";
import { getDeployedAddress } from "../src/DeploymentUtils";
import { SOLANA_SPOKE_STATE_SEED } from "../src/svm/web3-v1/constants";
import { getSolanaChainId } from "../src/svm/web3-v1/helpers";
import { CHAIN_IDs } from "../utils";
import { USDC } from "./consts";
import { getAssociatedTokenAddressSync } from "@solana/spl-token";
import { PublicKey } from "@solana/web3.js";

const fromBase58 = (input: string) => {
  const decodedBytes = utils.bytes.bs58.decode(input);
  return "0x" + Buffer.from(decodedBytes).toString("hex");
};

const CCTP_TOKEN_MESSENGER_V1 = {
  [CHAIN_IDs.MAINNET]: "0xbd3fa81b58ba92a82136038b25adec7066af3155",
  [CHAIN_IDs.SEPOLIA]: "0x9f3B8679c73C2Fef8b59B4f3444d4e156fb70AA5",
};

const CCTP_MESSAGE_TRANSMITTER_V1 = {
  [CHAIN_IDs.MAINNET]: "0x0a992d191deec32afe36203ad87d7d289a738f81",
  [CHAIN_IDs.SEPOLIA]: "0x7865fAfC2db2093669d92c0F33AeEF291086BEFD",
};

const SOLANA_USDC = {
  mainnet: "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v",
  devnet: "4zMMC9srt5Ri5X14GAgXhaHii3GnPAEERYPJgZJDncDU",
};

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployer } = await hre.getNamedAccounts();
  const chainId = parseInt(await hre.getChainId());
  const solanaTargetNetwork = chainId == CHAIN_IDs.MAINNET ? "mainnet" : "devnet";

  const l1Usdc = USDC[chainId];
  const cctpTokenMessenger = CCTP_TOKEN_MESSENGER_V1[chainId];
  const cctpMessageTransmitter = CCTP_MESSAGE_TRANSMITTER_V1[chainId];
  const solanaSpokePool = getDeployedAddress("SvmSpoke", getSolanaChainId(solanaTargetNetwork).toString());
  if (!solanaSpokePool) {
    throw new Error("SvmSpoke not deployed");
  }
  const solanaUsdc = fromBase58(SOLANA_USDC[solanaTargetNetwork]);
  const mint = new PublicKey(SOLANA_USDC[solanaTargetNetwork]);
  const seeds = [Buffer.from("state"), SOLANA_SPOKE_STATE_SEED.toArrayLike(Buffer, "le", 8)];
  const [state] = PublicKey.findProgramAddressSync(seeds, new PublicKey(solanaSpokePool));
  const vault = getAssociatedTokenAddressSync(mint, state, true);
  const solanaSpokePoolUsdcVault = fromBase58(vault.toBase58());
  const solanaSpokePoolBytes32 = fromBase58(solanaSpokePool);

  await hre.deployments.deploy("Solana_Adapter", {
    from: deployer,
    log: true,
    skipIfAlreadyDeployed: true,
    args: [
      l1Usdc,
      cctpTokenMessenger,
      cctpMessageTransmitter,
      solanaSpokePoolBytes32,
      solanaUsdc,
      solanaSpokePoolUsdcVault,
    ],
  });
};

module.exports = func;
func.tags = ["Solana_Adapter"];
