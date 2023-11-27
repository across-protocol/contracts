import { DeployFunction } from "hardhat-deploy/types";
import { L2_ADDRESS_MAP } from "./consts";
import { deployNewProxy, getSpokePoolDeploymentInfo } from "../utils/utils.hre";
import { HardhatRuntimeEnvironment } from "hardhat/types";

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { hubPool, spokeChainId } = await getSpokePoolDeploymentInfo(hre);

  // Initialize deposit counter to very high number of deposits to avoid duplicate deposit ID's
  // with deprecated spoke pool.
  // Set hub pool as cross domain admin since it delegatecalls the Adapter logic.
  const constructorArgs = [1_000_000, L2_ADDRESS_MAP[spokeChainId].l2GatewayRouter, hubPool.address, hubPool.address];
  await deployNewProxy("Arbitrum_SpokePool", constructorArgs, {
    constructorArgs: [L2_ADDRESS_MAP[spokeChainId].l2Weth, 3600, 32400],
  });
};
module.exports = func;
func.tags = ["ArbitrumSpokePool", "arbitrum"];
