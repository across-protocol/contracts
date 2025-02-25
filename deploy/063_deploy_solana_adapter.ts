import { getAssociatedTokenAddressSync } from "@solana/spl-token";
import { PublicKey } from "@solana/web3.js";
import { DeployFunction } from "hardhat-deploy/types";
import { HardhatRuntimeEnvironment } from "hardhat/types";
import { getDeployedAddress } from "../src/DeploymentUtils";
import { fromBase58ToBytes32 } from "../src/svm/web3-v1";
import { SOLANA_SPOKE_STATE_SEED } from "../src/svm/web3-v1/constants";
import { getSolanaChainId } from "../src/svm/web3-v1/helpers";
import { CHAIN_IDs } from "../utils";
import { L1_ADDRESS_MAP, USDC } from "./consts";

const SOLANA_USDC = {
  mainnet: "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v",
  devnet: "4zMMC9srt5Ri5X14GAgXhaHii3GnPAEERYPJgZJDncDU",
};

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployer } = await hre.getNamedAccounts();
  const chainId = parseInt(await hre.getChainId());
  const solanaTargetNetwork = chainId == CHAIN_IDs.MAINNET ? "mainnet" : "devnet";

  const l1Usdc = USDC[chainId];
  const cctpTokenMessenger = L1_ADDRESS_MAP[chainId].cctpTokenMessenger;
  const cctpMessageTransmitter = L1_ADDRESS_MAP[chainId].cctpMessageTransmitter;
  const solanaSpokePool = getDeployedAddress("SvmSpoke", getSolanaChainId(solanaTargetNetwork).toString());
  if (!solanaSpokePool) {
    throw new Error("SvmSpoke not deployed");
  }
  const solanaUsdc = fromBase58ToBytes32(SOLANA_USDC[solanaTargetNetwork]);
  const mint = new PublicKey(SOLANA_USDC[solanaTargetNetwork]);
  const seeds = [Buffer.from("state"), SOLANA_SPOKE_STATE_SEED.toArrayLike(Buffer, "le", 8)];
  const [state] = PublicKey.findProgramAddressSync(seeds, new PublicKey(solanaSpokePool));
  const vault = getAssociatedTokenAddressSync(mint, state, true);
  const solanaSpokePoolUsdcVault = fromBase58ToBytes32(vault.toBase58());
  const solanaSpokePoolBytes32 = fromBase58ToBytes32(solanaSpokePool);
  const args = [
    l1Usdc,
    cctpTokenMessenger,
    cctpMessageTransmitter,
    solanaSpokePoolBytes32,
    solanaUsdc,
    solanaSpokePoolUsdcVault,
  ];
  const instance = await hre.deployments.deploy("Solana_Adapter", {
    from: deployer,
    log: true,
    skipIfAlreadyDeployed: true,
    args,
  });
  await hre.run("verify:verify", { address: instance.address, constructorArguments: args });
};

module.exports = func;
func.tags = ["SolanaAdapter", "mainnet"];
