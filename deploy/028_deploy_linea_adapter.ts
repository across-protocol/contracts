import { L1_ADDRESS_MAP, WETH, USDCe } from "./consts";
import { DeployFunction } from "hardhat-deploy/types";
import { HardhatRuntimeEnvironment } from "hardhat/types";

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployer } = await hre.getNamedAccounts();
  const chainId = parseInt(await hre.getChainId());

  await hre.deployments.deploy("Linea_Adapter", {
    from: deployer,
    log: true,
    skipIfAlreadyDeployed: true,
    args: [
      WETH[chainId],
      L1_ADDRESS_MAP[chainId].lineaMessageService,
      L1_ADDRESS_MAP[chainId].lineaTokenBridge,
      // TODO: USDC.e on Linea will be upgraded to USDC so eventually we should add a USDC entry for Linea in consts
      // and read from there instead of using the L1 USDC.e address.
      USDCe[chainId],
      L1_ADDRESS_MAP[chainId].cctpV2TokenMessenger,
    ],
  });
};

module.exports = func;
func.dependencies = ["HubPool"];
func.tags = ["LineaAdapter", "mainnet"];
