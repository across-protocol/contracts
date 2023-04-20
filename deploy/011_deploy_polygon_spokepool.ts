import "hardhat-deploy";
import hre from "hardhat";
import { L2_ADDRESS_MAP } from "./consts";
import { deployNewProxy } from "../utils";

const func = async function () {
  const hubPool = await hre.companionNetworks.l1.deployments.get("HubPool");
  const chainId = await hre.getChainId();
  console.log(`Using L1 (chainId ${chainId}) hub pool @ ${hubPool.address}`);

  // Initialize deposit counter to very high number of deposits to avoid duplicate deposit ID's
  // with deprecated spoke pool.
  // Set hub pool as cross domain admin since it delegatecalls the Adapter logic.
  const constructorArgs = [
    1_000_000,
    // The same token bridger must be deployed on mainnet and polygon, so its easier
    // to reuse it.
    "0x0330E9b4D0325cCfF515E81DFbc7754F2a02ac57",
    hubPool.address,
    hubPool.address,
    L2_ADDRESS_MAP[chainId].wMatic,
    L2_ADDRESS_MAP[chainId].fxChild,
  ];
  await deployNewProxy("Polygon_SpokePool", constructorArgs);
};

module.exports = func;
func.dependencies = ["PolygonTokenBridgerL2"];
func.tags = ["PolygonSpokePool", "polygon"];
