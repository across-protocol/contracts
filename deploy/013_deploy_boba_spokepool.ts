import { DeployFunction } from "hardhat-deploy/types";
import { HardhatRuntimeEnvironment } from "hardhat/types";
import { deployNewProxy, getSpokePoolDeploymentInfo } from "../utils/utils.hre";
import { FILL_DEADLINE_BUFFER, QUOTE_TIME_BUFFER } from "./consts";

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { hubPool } = await getSpokePoolDeploymentInfo(hre);

  // Initialize deposit counter to very high number of deposits to avoid duplicate deposit ID's
  // with deprecated spoke pool.
  // Set hub pool as cross domain admin since it delegatecalls the Adapter logic.
  const initArgs = [1_000_000, hubPool.address, hubPool.address];

  // Construct this spokepool with a:
  //    * A WETH address of the WETH address
  //    * A depositQuoteTimeBuffer of 1 hour
  //    * A fillDeadlineBuffer of 6 hours
  const constructorArgs = [
    "0xDeadDeAddeAddEAddeadDEaDDEAdDeaDDeAD0000",
    QUOTE_TIME_BUFFER,
    FILL_DEADLINE_BUFFER
  ];
  await deployNewProxy("Boba_SpokePool", constructorArgs, initArgs);
};
module.exports = func;
func.tags = ["BobaSpokePool", "boba"];
