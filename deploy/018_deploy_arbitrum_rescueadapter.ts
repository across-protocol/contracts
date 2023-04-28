import { L1_ADDRESS_MAP } from "./consts";
import { DeployFunction } from "hardhat-deploy/types";

const func: DeployFunction = async function (hre: any) {
  const { deployments, getNamedAccounts, getChainId } = hre;
  const { deploy } = deployments;

  const { deployer } = await getNamedAccounts();

  const chainId = parseInt(await getChainId());

  await deploy("Arbitrum_RescueAdapter", {
    from: deployer,
    log: true,
    skipIfAlreadyDeployed: true,
    args: [L1_ADDRESS_MAP[chainId].l1ArbitrumInbox],
  });
};

module.exports = func;
func.tags = ["ArbitrumRescueAdapter", "mainnet"];
