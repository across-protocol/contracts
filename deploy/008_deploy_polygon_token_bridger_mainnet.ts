import { DeployFunction } from "hardhat-deploy/types";
import { L1_ADDRESS_MAP, POLYGON_CHAIN_IDS } from "./consts";
import { HardhatRuntimeEnvironment } from "hardhat/types";

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
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
      L1_ADDRESS_MAP[chainId].l2WrappedMatic,
      chainId,
      POLYGON_CHAIN_IDS[chainId],
    ],
    deterministicDeployment: "0x1234", // Salt for the create2 call.
  });
};

module.exports = func;
func.dependencies = ["HubPool"];
func.tags = ["PolygonTokenBridgerL1", "mainnet"];
