import { DeployFunction } from "hardhat-deploy/types";
import { HardhatRuntimeEnvironment } from "hardhat/types";
import { L1_ADDRESS_MAP, POLYGON_CHAIN_IDS, WETH, WMATIC } from "./consts";

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployments, getNamedAccounts, getChainId } = hre;
  const { deploy } = deployments;

  const { deployer } = await getNamedAccounts();

  const hubChainId = parseInt(await getChainId());
  const spokeChainId = POLYGON_CHAIN_IDS[hubChainId];
  const hubPool = await deployments.get("HubPool");

  await deploy("PolygonTokenBridger", {
    from: deployer,
    log: true,
    skipIfAlreadyDeployed: true,
    args: [
      hubPool.address,
      L1_ADDRESS_MAP[hubChainId].polygonRegistry,
      WETH[hubChainId],
      WMATIC[spokeChainId],
      hubChainId,
      spokeChainId,
    ],
    deterministicDeployment: "0x1234", // Salt for the create2 call.
  });
};

module.exports = func;
func.dependencies = ["HubPool"];
func.tags = ["PolygonTokenBridgerL1", "mainnet"];
