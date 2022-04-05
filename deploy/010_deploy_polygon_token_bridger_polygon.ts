// This import is needed to override the definition of the HardhatRuntimeEnvironment type.
import "hardhat-deploy";
import { HardhatRuntimeEnvironment } from "hardhat/types/runtime";

import { L1_ADDRESS_MAP } from "./consts";

const func = async function (hre: HardhatRuntimeEnvironment) {
  const { deployments, getNamedAccounts, getChainId } = hre;
  const { deploy } = deployments;

  const { deployer } = await getNamedAccounts();

  const chainId = parseInt(await getChainId());
  const l1ChainId = parseInt(await hre.companionNetworks.l1.getChainId());
  const l1HubPool = await hre.companionNetworks.l1.deployments.get("HubPool");

  await deploy("PolygonTokenBridger", {
    from: deployer,
    log: true,
    skipIfAlreadyDeployed: true,
    args: [
      l1HubPool.address,
      L1_ADDRESS_MAP[l1ChainId].polygonRegistry,
      L1_ADDRESS_MAP[l1ChainId].weth,
      l1ChainId,
      chainId,
    ],
    deterministicDeployment: "0x1234", // Salt for the create2 call.
  });
};

module.exports = func;
func.tags = ["PolygonTokenBridgerL2", "polygon"];
