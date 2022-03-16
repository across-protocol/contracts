// This import is needed to override the definition of the HardhatRuntimeEnvironment type.
import "hardhat-deploy";
import { HardhatRuntimeEnvironment } from "hardhat/types/runtime";

import { L2_ADDRESS_MAP } from "./consts";

const func = async function (hre: HardhatRuntimeEnvironment) {
  const { deployments, getNamedAccounts, getChainId } = hre;
  const { deploy } = deployments;

  const { deployer } = await getNamedAccounts();

  const chainId = parseInt(await getChainId());
  const l1HubPool = await hre.companionNetworks.l1.deployments.get("HubPool");
  const polygonTokenBridger = await deployments.get("PolygonTokenBridger");

  await deploy("Polygon_SpokePool", {
    from: deployer,
    log: true,
    skipIfAlreadyDeployed: true,
    args: [
      polygonTokenBridger.address,
      l1HubPool.address,
      l1HubPool.address,
      L2_ADDRESS_MAP[chainId].wMatic,
      L2_ADDRESS_MAP[chainId].fxChild,
      "0x0000000000000000000000000000000000000000",
    ],
  });
};

module.exports = func;
func.dependencies = ["PolygonTokenBridgerL2"];
func.tags = ["PolygonSpokePool", "polygon"];
