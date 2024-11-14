import { DeployFunction } from "hardhat-deploy/types";
import { HardhatRuntimeEnvironment } from "hardhat/types";

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployer } = await hre.getNamedAccounts();

  // @note if deploying this contract on a chain like Linea that only supports up to
  // solc 0.8.19, the hardhat.config solc version needs to be overridden and this
  // contract needs to be recompiled.
  await hre.deployments.deploy("Multicall3", {
    contract: "Multicall3",
    from: deployer,
    log: true,
    skipIfAlreadyDeployed: true,
    args: [],
  });
};
module.exports = func;
func.tags = ["Multicall3"];
