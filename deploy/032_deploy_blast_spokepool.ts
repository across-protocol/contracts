import { deployNewProxy, getSpokePoolDeploymentInfo } from "../utils/utils.hre";
import { DeployFunction } from "hardhat-deploy/types";
import { HardhatRuntimeEnvironment } from "hardhat/types";
import { L2_ADDRESS_MAP } from "./consts";
import { ZERO_ADDRESS } from "@uma/common";

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { hubPool, spokeChainId } = await getSpokePoolDeploymentInfo(hre);

  const initArgs = [
    // Initialize deposit counter to very high number of deposits to avoid duplicate deposit ID's
    // with deprecated spoke pool.
    1_000_000,
    // Set hub pool as cross domain admin since it delegatecalls the Adapter logic.
    hubPool.address,
    hubPool.address,
  ];
  // Construct this spokepool with a:
  //    * A WETH address of the WETH address
  //    * A depositQuoteTimeBuffer of 1 hour
  //    * A fillDeadlineBuffer of 6 hours
  //    * Native USDC address on L2
  //    * CCTP token messenger address on L2
  const constructorArgs = [
    "0x4300000000000000000000000000000000000004",
    3600,
    21600,
    L2_ADDRESS_MAP[spokeChainId].usdb,
    // L2_ADDRESS_MAP[spokeChainId].cctpTokenMessenger,
    // For now, we are not using the CCTP bridge and can disable by setting
    // the cctpTokenMessenger to the zero address.
    ZERO_ADDRESS,
  ];
  await deployNewProxy("Blast_SpokePool", constructorArgs, initArgs, spokeChainId === 81457);
};
module.exports = func;
func.tags = ["BlastSpokePool", "blast"];
