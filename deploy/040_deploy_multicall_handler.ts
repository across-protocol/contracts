import { DeployFunction } from "hardhat-deploy/types";
import { HardhatRuntimeEnvironment } from "hardhat/types";

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployments, getNamedAccounts } = hre;
  const { deploy } = deployments;

  const { deployer } = await getNamedAccounts();

  await deploy("Multicallhandler", {
    contract: "MulticallHandler",
    from: deployer,
    log: true,
    skipIfAlreadyDeployed: true,
    args: [],
  });
};
module.exports = func;
func.tags = ["Multicallhandler"];
