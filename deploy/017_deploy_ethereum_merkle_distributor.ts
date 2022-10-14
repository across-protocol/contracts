import "hardhat-deploy";
import { HardhatRuntimeEnvironment } from "hardhat/types/runtime";

const func = async function (hre: HardhatRuntimeEnvironment) {
  const { deployments, getNamedAccounts } = hre;
  const { deploy } = deployments;

  const { deployer } = await getNamedAccounts();

  await deploy("MerkleDistributor", {
    from: deployer,
    log: true,
    skipIfAlreadyDeployed: true,
    args: [],
  });
};

module.exports = func;
func.tags = ["MerkleDistributor", "mainnet"];
