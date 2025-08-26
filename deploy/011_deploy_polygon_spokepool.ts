import { DeployFunction } from "hardhat-deploy/types";
import { HardhatRuntimeEnvironment } from "hardhat/types";
import { deployNewProxy, getSpokePoolDeploymentInfo } from "../utils/utils.hre";
import { FILL_DEADLINE_BUFFER, L2_ADDRESS_MAP, QUOTE_TIME_BUFFER, USDC, WMATIC } from "./consts";
import { getOftEid, toWei } from "../utils/utils";

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { hubPool, hubChainId, spokeChainId } = await getSpokePoolDeploymentInfo(hre);

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
  ];

  const oftEid = getOftEid(hubChainId);
  // Fee cap of 22K POL is roughly equivalent to $5K at current POL price of ~0.23
  const oftFeeCap = toWei(22000);
  const constructorArgs = [
    WMATIC[spokeChainId],
    QUOTE_TIME_BUFFER,
    FILL_DEADLINE_BUFFER,
    USDC[spokeChainId],
    L2_ADDRESS_MAP[spokeChainId].cctpTokenMessenger,
    oftEid,
    oftFeeCap,
  ];
  await deployNewProxy("Polygon_SpokePool", constructorArgs, initArgs);
};

module.exports = func;
func.tags = ["PolygonSpokePool", "polygon"];
