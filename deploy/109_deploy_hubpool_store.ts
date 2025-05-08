import { DeployFunction } from "hardhat-deploy/types";
import { HardhatRuntimeEnvironment } from "hardhat/types";

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployer } = await hre.getNamedAccounts();
  const hubPool = await hre.deployments.get("HubPool");

  const args = [hubPool.address];
  const instance = await hre.deployments.deploy("HubPoolStore", {
    from: deployer,
    log: true,
    skipIfAlreadyDeployed: true,
    args,
  });
  await hre.run("verify:verify", { address: instance.address, constructorArguments: args });
};

module.exports = func;
func.tags = ["HubPoolStore"];
