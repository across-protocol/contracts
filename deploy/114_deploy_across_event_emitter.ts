import { DeployFunction } from "hardhat-deploy/types";
import { HardhatRuntimeEnvironment } from "hardhat/types";

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployer } = await hre.getNamedAccounts();
  const instance = await hre.deployments.deploy("AcrossEventEmitter", {
    from: deployer,
    log: true,
    skipIfAlreadyDeployed: true,
    deterministicDeployment: "0x1234", // Salt for create2
  });
  await hre.run("verify:verify", { address: instance.address });
};

module.exports = func;
func.tags = ["AcrossEventEmitter"];
