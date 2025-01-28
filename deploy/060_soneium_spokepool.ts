import { DeployFunction } from "hardhat-deploy/types";
import { HardhatRuntimeEnvironment } from "hardhat/types";
import { deployNewProxy, getSpokePoolDeploymentInfo } from "../utils/utils.hre";
import { FILL_DEADLINE_BUFFER, WETH, QUOTE_TIME_BUFFER, ZERO_ADDRESS, USDCe } from "./consts";

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { hubPool, spokeChainId } = await getSpokePoolDeploymentInfo(hre);

  const initArgs = [
    1,
    // Set hub pool as cross domain admin since it delegatecalls the Adapter logic.
    hubPool.address,
    hubPool.address,
  ];
  const constructorArgs = [
    WETH[spokeChainId],
    QUOTE_TIME_BUFFER,
    FILL_DEADLINE_BUFFER,
    // Cher's bridged USDC is upgradeable to native. There are not two different
    // addresses for bridges/native USDC. This address is also used in the spoke pool
    // to determine whether to use CCTP (in the future) or the custom USDC bridge.
    USDCe[spokeChainId],
    // L2_ADDRESS_MAP[spokeChainId].cctpTokenMessenger,
    // For now, we are not using the CCTP bridge and can disable by setting
    // the cctpTokenMessenger to the zero address.
    ZERO_ADDRESS,
  ];
  await deployNewProxy("Soneium_SpokePool", constructorArgs, initArgs);
};
module.exports = func;
func.tags = ["SoneiumSpokePool", "cher"];
