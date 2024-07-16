import { HardhatRuntimeEnvironment } from "hardhat/types";
import { L1_ADDRESS_MAP, WETH } from "./consts";
import { DeployFunction } from "hardhat-deploy/types";

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployments, getNamedAccounts, getChainId } = hre;
  const { deploy } = deployments;

  const { deployer } = await getNamedAccounts();

  const chainId = parseInt(await getChainId());

  await deploy("Boba_Adapter", {
    from: deployer,
    log: true,
    skipIfAlreadyDeployed: true,
    args: [WETH[chainId], L1_ADDRESS_MAP[chainId].bobaCrossDomainMessenger, L1_ADDRESS_MAP[chainId].bobaStandardBridge],
  });
};

module.exports = func;
func.dependencies = ["HubPool"];
func.tags = ["BobaAdapter", "mainnet"];
