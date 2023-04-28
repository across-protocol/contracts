import { DeployFunction } from "hardhat-deploy/types";
import { HardhatRuntimeEnvironment } from "hardhat/types/runtime";

const func: DeployFunction = async function (hre: any) {
  const { deployments, getNamedAccounts } = hre;
  const { deploy } = deployments;

  const { deployer } = await getNamedAccounts();

  await deploy("AcrossMerkleDistributor", {
    from: deployer,
    log: true,
    skipIfAlreadyDeployed: true,
    args: [],
  });
};

module.exports = func;
func.tags = ["MerkleDistributor", "mainnet"];
