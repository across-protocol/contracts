import { DeployFunction } from "hardhat-deploy/types";
import { L1_ADDRESS_MAP } from "./consts";
import { HardhatRuntimeEnvironment } from "hardhat/types";

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
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
      L1_ADDRESS_MAP[l1ChainId].l2WrappedMatic,
      l1ChainId,
      chainId,
    ],
    deterministicDeployment: "0x1234", // Salt for the create2 call.
  });
};

module.exports = func;
func.tags = ["PolygonTokenBridgerL2", "polygon"];
