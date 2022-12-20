import "hardhat-deploy";
import { HardhatRuntimeEnvironment } from "hardhat/types/runtime";

const func = async function (hre: HardhatRuntimeEnvironment) {
  const { deployments, getNamedAccounts } = hre;
  const { deploy } = deployments;

  const { deployer } = await getNamedAccounts();

  const spokePool = await deployments.get("Polygon_SpokePool");
  console.log(`Using spoke pool @ ${spokePool.address}`);
  const tokenBridger = await deployments.get("PolygonTokenBridger");

  await deploy("Polygon_SpokeAdapter", {
    from: deployer,
    log: true,
    skipIfAlreadyDeployed: true,
    args: [spokePool.address, tokenBridger.address],
  });
};

module.exports = func;
func.dependencies = ["PolygonSpokePool"];
func.tags = ["PolygonSpokeAdapter", "polygon"];
