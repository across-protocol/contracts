import { L1_ADDRESS_MAP, WETH, USDC } from "./consts";
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
      // TODO: Requires USDC Linea address to be added, currently only USDC.e is set for Linea
      USDC[chainId],
      L1_ADDRESS_MAP[chainId].cctpTokenMessenger,
    ],
  });
};

module.exports = func;
func.dependencies = ["HubPool"];
func.tags = ["LineaAdapter", "mainnet"];
