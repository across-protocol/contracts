import { DeployFunction } from "hardhat-deploy/types";
import { HardhatRuntimeEnvironment } from "hardhat/types";
import { deployNewProxy, getSpokePoolDeploymentInfo } from "../utils/utils.hre";
import { FILL_DEADLINE_BUFFER, USDCe, WETH, QUOTE_TIME_BUFFER, ZERO_ADDRESS } from "./consts";

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { hubPool, spokeChainId } = await getSpokePoolDeploymentInfo(hre);

  // For now, we are not using the CCTP bridge and can disable by setting
  // the cctpTokenMessenger to the zero address.
  const cctpTokenMessenger = ZERO_ADDRESS; // L2_ADDRESS_MAP[spokeChainId].cctpTokenMessenger,

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
    USDCe[spokeChainId],
    cctpTokenMessenger,
  ];
  await deployNewProxy("Lisk_SpokePool", constructorArgs, initArgs);
};
module.exports = func;
func.tags = ["LiskSpokePool", "lisk"];
