import "hardhat-deploy";
import { HardhatRuntimeEnvironment } from "hardhat/types/runtime";

const func = async function (hre: HardhatRuntimeEnvironment) {
  const { deployments, getNamedAccounts, getChainId } = hre;
  const { deploy } = deployments;

  const { deployer } = await getNamedAccounts();

  const chainId = parseInt(await getChainId());
  const hubPool = await deploy("HubPool", { from: deployer, log: true, skipIfAlreadyDeployed: true });

  await deploy("BondToken", {
    from: deployer,
    log: true,
    skipIfAlreadyDeployed: true,
    args: [hubPool.address],
    libraries: {},
  });
};
module.exports = func;
func.tags = ["BondToken", "mainnet"];
