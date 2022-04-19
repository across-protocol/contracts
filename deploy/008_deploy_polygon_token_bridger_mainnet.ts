// This import is needed to override the definition of the HardhatRuntimeEnvironment type.
import "hardhat-deploy";
import { HardhatRuntimeEnvironment } from "hardhat/types/runtime";

import { L1_ADDRESS_MAP, POLYGON_CHAIN_IDS } from "./consts";

const func = async function (hre: HardhatRuntimeEnvironment) {
  const { deployments, getNamedAccounts, getChainId } = hre;
  const { deploy } = deployments;

  const { deployer } = await getNamedAccounts();

  const chainId = parseInt(await getChainId());
  const hubPool = await deployments.get("HubPool");

  await deploy("PolygonTokenBridger", {
    from: deployer,
    log: true,
    skipIfAlreadyDeployed: true,
    args: [
      hubPool.address,
      L1_ADDRESS_MAP[chainId].polygonRegistry,
      L1_ADDRESS_MAP[chainId].weth,
      chainId,
      POLYGON_CHAIN_IDS[chainId],
    ],
    deterministicDeployment: "0x1234", // Salt for the create2 call.
  });
};

module.exports = func;
func.dependencies = ["HubPool"];
func.tags = ["PolygonTokenBridgerL1", "mainnet"];
