import { HardhatRuntimeEnvironment } from "hardhat/types";
import { L1_ADDRESS_MAP, WETH } from "./consts";
import { DeployFunction } from "hardhat-deploy/types";

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployer } = await hre.getNamedAccounts();
  const chainId = parseInt(await hre.getChainId());

  await hre.deployments.deploy("Boba_Adapter", {
    from: deployer,
    log: true,
    skipIfAlreadyDeployed: true,
    args: [WETH[chainId], L1_ADDRESS_MAP[chainId].bobaCrossDomainMessenger, L1_ADDRESS_MAP[chainId].bobaStandardBridge],
  });
};

module.exports = func;
func.dependencies = ["HubPool"];
func.tags = ["BobaAdapter", "mainnet"];
