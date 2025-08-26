import { DeployFunction } from "hardhat-deploy/types";
import { HardhatRuntimeEnvironment } from "hardhat/types";
import { deployNewProxy, getSpokePoolDeploymentInfo } from "../utils/utils.hre";
import { FILL_DEADLINE_BUFFER, L2_ADDRESS_MAP, QUOTE_TIME_BUFFER, USDC, WETH } from "./consts";
import { getOftEid, toWei } from "../utils/utils";

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { hubPool, hubChainId, spokeChainId } = await getSpokePoolDeploymentInfo(hre);

  const initArgs = [
    // Initialize deposit counter to very high number of deposits to avoid duplicate deposit ID's
    // with deprecated spoke pool.
    1_000_000,
    L2_ADDRESS_MAP[spokeChainId].l2GatewayRouter,
    // Set hub pool as cross domain admin since it delegatecalls the Adapter logic.
    hubPool.address,
    hubPool.address,
  ];

  const oftEid = getOftEid(hubChainId);
  const oftFeeCap = toWei(1); // 1 eth fee cap
  const constructorArgs = [
    WETH[spokeChainId],
    QUOTE_TIME_BUFFER,
    FILL_DEADLINE_BUFFER,
    USDC[spokeChainId],
    L2_ADDRESS_MAP[spokeChainId].cctpTokenMessenger,
    oftEid,
    oftFeeCap,
  ];
  await deployNewProxy("Arbitrum_SpokePool", constructorArgs, initArgs);
};
module.exports = func;
func.tags = ["ArbitrumSpokePool", "arbitrum"];
