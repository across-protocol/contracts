// import { DeployFunction } from "hardhat-deploy/types";
// import { HardhatRuntimeEnvironment } from "hardhat/types";
// import { fromBase58ToBytes32 } from "../utils/utils";

// const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
//   const { deployer } = await hre.getNamedAccounts();
//   const chainId = parseInt(await hre.getChainId());

//   const usdc = "0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238";
//   const cctpTokenMessenger = "0x9f3B8679c73C2Fef8b59B4f3444d4e156fb70AA5";
//   const cctpMessageTransmitter = "0x7865fAfC2db2093669d92c0F33AeEF291086BEFD";

//   const solanaSpokePoolBytes32 = fromBase58ToBytes32("YVMQN27RnCNt23NRxzJPumXRd8iovEfKtzkqyMc5vDt");
//   const solanaUsdcBytes32 = fromBase58ToBytes32("4zMMC9srt5Ri5X14GAgXhaHii3GnPAEERYPJgZJDncDU");
//   const solanaSpokePoolUsdcVaultBytes32 = fromBase58ToBytes32("Crv73j9qx9SS4AQN5kBf8hZQiPT9fnNFg71HWCKT4PLb");

//   await hre.deployments.deploy("Solana_Adapter", {
//     from: deployer,
//     log: true,
//     skipIfAlreadyDeployed: false,
//     args: [
//       usdc,
//       cctpTokenMessenger,
//       cctpMessageTransmitter,
//       solanaSpokePoolBytes32,
//       solanaUsdcBytes32,
//       solanaSpokePoolUsdcVaultBytes32,
//     ],
//   });
// };

// module.exports = func;
// func.tags = ["SolanaAdapter", "mainnet"];
