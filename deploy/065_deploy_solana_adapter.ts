import assert from "assert";
import { HardhatRuntimeEnvironment } from "hardhat/types";
import { DeployFunction } from "hardhat-deploy/types";
import { USDC, L1_ADDRESS_MAP } from "./consts";
import {
  fromBase58ToBytes32,
  getSolanaChainId,
  SOLANA_USDC_MAINNET,
  SOLANA_USDC_DEVNET,
  SOLANA_SPOKE_STATE_SEED,
} from "../src/svm/web3-v1";
import { getDeployedAddress } from "../src/DeploymentUtils";
import { PublicKey } from "@solana/web3.js";
import { getAssociatedTokenAddressSync, TOKEN_PROGRAM_ID, ASSOCIATED_TOKEN_PROGRAM_ID } from "@solana/spl-token";

/**
 * Note:
 * This adapter supports only USDC for Solana mapping EVM sepolia to SVM devnet and EVM mainnet to SVM mainnet.
 *
 * Usage:
 * $ yarn hardhat deploy --network mainnet --tags solanaAdapter
 */

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  assert(hre.network.name === "mainnet" || hre.network.name === "sepolia", "EVM network must be mainnet or sepolia");
  const solanaCluster = hre.network.name === "mainnet" ? "mainnet" : "devnet";
  const svmChainId = getSolanaChainId(solanaCluster).toString();

  const svmSpokePool = getDeployedAddress("SvmSpoke", svmChainId);
  assert(svmSpokePool !== undefined, "SvmSpoke program not deployed for the selected cluster");

  const solanaUsdc = solanaCluster === "mainnet" ? SOLANA_USDC_MAINNET : SOLANA_USDC_DEVNET;
  const [statePda, _] = PublicKey.findProgramAddressSync(
    [Buffer.from("state"), SOLANA_SPOKE_STATE_SEED.toArrayLike(Buffer, "le", 8)],
    new PublicKey(svmSpokePool)
  );
  const solanaUsdcVault = getAssociatedTokenAddressSync(
    new PublicKey(solanaUsdc),
    statePda,
    true,
    TOKEN_PROGRAM_ID,
    ASSOCIATED_TOKEN_PROGRAM_ID
  ).toBase58();

  const { deployer } = await hre.getNamedAccounts();
  const chainId = parseInt(await hre.getChainId());

  const constructorArguments = [
    USDC[chainId],
    L1_ADDRESS_MAP[chainId].cctpTokenMessenger,
    L1_ADDRESS_MAP[chainId].cctpMessageTransmitter,
    fromBase58ToBytes32(svmSpokePool),
    fromBase58ToBytes32(solanaUsdc),
    fromBase58ToBytes32(solanaUsdcVault),
  ];

  const { address: deployment } = await hre.deployments.deploy("Solana_Adapter", {
    from: deployer,
    log: true,
    skipIfAlreadyDeployed: true,
    args: constructorArguments,
  });

  await hre.run("verify:verify", { address: deployment, constructorArguments });
};

module.exports = func;
func.tags = ["solanaAdapter", "mainnet"];
