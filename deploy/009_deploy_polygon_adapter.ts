// This import is needed to override the definition of the HardhatRuntimeEnvironment type.
import "hardhat-deploy";
import { HardhatRuntimeEnvironment } from "hardhat/types/runtime";

import { L1_ADDRESS_MAP } from "./consts";

const func = async function (hre: HardhatRuntimeEnvironment) {
  const { deployments, getNamedAccounts, getChainId } = hre;
  const { deploy } = deployments;

  const { deployer } = await getNamedAccounts();

  const chainId = parseInt(await getChainId());

  await deploy("Polygon_Adapter", {
    from: deployer,
    log: true,
    skipIfAlreadyDeployed: false,
    args: [
      L1_ADDRESS_MAP[chainId].polygonRootChainManager,
      L1_ADDRESS_MAP[chainId].polygonFxRoot,
      L1_ADDRESS_MAP[chainId].polygonERC20Predicate,
      L1_ADDRESS_MAP[chainId].weth,
    ],
  });
};

module.exports = func;
func.tags = ["PolygonAdapter", "mainnet"];
