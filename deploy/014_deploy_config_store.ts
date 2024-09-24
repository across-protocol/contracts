import { DeployFunction } from "hardhat-deploy/types";
import { HardhatRuntimeEnvironment } from "hardhat/types";

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployer } = await hre.getNamedAccounts();

  await hre.deployments.deploy("AcrossConfigStore", {
    from: deployer,
    log: true,
    skipIfAlreadyDeployed: true,
  });
};

module.exports = func;
func.tags = ["AcrossConfigStore", "mainnet"];
