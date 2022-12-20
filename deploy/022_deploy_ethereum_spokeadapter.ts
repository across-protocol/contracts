import "hardhat-deploy";
import { HardhatRuntimeEnvironment } from "hardhat/types/runtime";

const func = async function (hre: HardhatRuntimeEnvironment) {
  const { deployments, getNamedAccounts } = hre;
  const { deploy } = deployments;

  const { deployer } = await getNamedAccounts();

  const spokePool = await deployments.get("Polygon_SpokePool");
  console.log(`Using spoke pool @ ${spokePool.address}`);

  await deploy("Polygon_SpokeAdapter", {
    from: deployer,
    log: true,
    skipIfAlreadyDeployed: true,
    args: [spokePool.address],
  });
};

module.exports = func;
func.dependencies = ["EthereumSpokePool"];
func.tags = ["EthereumSpokeAdapter", "mainnet"];
