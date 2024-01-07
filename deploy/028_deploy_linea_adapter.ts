import { L1_ADDRESS_MAP } from "./consts";
import { DeployFunction } from "hardhat-deploy/types";
import { HardhatRuntimeEnvironment } from "hardhat/types";

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployments, getNamedAccounts, getChainId } = hre;
  const { deploy } = deployments;

  const { deployer } = await getNamedAccounts();

  const chainId = parseInt(await getChainId());

  await deploy("Linea_Adapter", {
    from: deployer,
    log: true,
    skipIfAlreadyDeployed: true,
    args: [
      L1_ADDRESS_MAP[chainId].weth,
      L1_ADDRESS_MAP[chainId].lineaMessageService,
      L1_ADDRESS_MAP[chainId].lineaTokenBridge,
      L1_ADDRESS_MAP[chainId].lineaUsdcBridge,
    ],
  });
};

module.exports = func;
func.dependencies = ["HubPool"];
func.tags = ["LineaAdapter", "mainnet"];
