import { DeployFunction } from "hardhat-deploy/types";
import { L2_ADDRESS_MAP } from "./consts";
import { deployNewProxy, getSpokePoolDeploymentInfo } from "../utils/utils.hre";
import { HardhatRuntimeEnvironment } from "hardhat/types";

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { hubPool, spokeChainId } = await getSpokePoolDeploymentInfo(hre);

  const initArgs = [
    // Initialize deposit counter to very high number of deposits to avoid duplicate deposit ID's
    // with deprecated spoke pool.
    1_000_000,
    // The same token bridger must be deployed on mainnet and polygon, so its easier
    // to reuse it.
    "0x0330E9b4D0325cCfF515E81DFbc7754F2a02ac57",
    // Set hub pool as cross domain admin since it delegatecalls the Adapter logic.
    hubPool.address,
    hubPool.address,
    L2_ADDRESS_MAP[spokeChainId].fxChild,
    // Native USDC address on L2
    L2_ADDRESS_MAP[spokeChainId].l2Usdc,
    L2_ADDRESS_MAP[spokeChainId].cctpTokenMessenger,
  ];

  // Construct this spokepool with a:
  //    * A WETH address of the WETH address
  //    * A depositQuoteTimeBuffer of 1 hour
  //    * A fillDeadlineBuffer of 9 hours
  const constructorArgs = [L2_ADDRESS_MAP[spokeChainId].wMatic, 3600, 32400];
  await deployNewProxy("Polygon_SpokePool", constructorArgs, initArgs);
};

module.exports = func;
func.tags = ["PolygonSpokePool", "polygon"];
