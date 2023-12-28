import { deployNewProxy, getSpokePoolDeploymentInfo } from "../utils/utils.hre";
import { DeployFunction } from "hardhat-deploy/types";
import { HardhatRuntimeEnvironment } from "hardhat/types";

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { hubPool } = await getSpokePoolDeploymentInfo(hre);

  // Initialize deposit counter to very high number of deposits to avoid duplicate deposit ID's
  // with deprecated spoke pool.
  // Set hub pool as cross domain admin since it delegatecalls the Adapter logic.
  const initArgs = [1_000_000, hubPool.address, hubPool.address];

  // Construct this spokepool with a:
  //    * A WETH address of the WETH address
  //    * A depositQuoteTimeBuffer of 1 hour
  //    * A fillDeadlineBuffer of 9 hours
  const constructorArgs = ["0x4200000000000000000000000000000000000006", 3600, 32400];
  await deployNewProxy("Optimism_SpokePool", constructorArgs, initArgs);
};
module.exports = func;
func.tags = ["OptimismSpokePool", "optimism"];
