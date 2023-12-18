import { L2_ADDRESS_MAP } from "./consts";
import { deployNewProxy, getSpokePoolDeploymentInfo } from "../utils/utils.hre";
import { DeployFunction } from "hardhat-deploy/types";
import { HardhatRuntimeEnvironment } from "hardhat/types";

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { getChainId } = hre;
  const { hubPool } = await getSpokePoolDeploymentInfo(hre);
  const chainId = parseInt(await getChainId());

  // Initialize deposit counter to very high number of deposits to avoid duplicate deposit ID's
  // with deprecated spoke pool.
  // Set hub pool as cross domain admin since it delegatecalls the Adapter logic.
  const initArgs = [1_000_000, hubPool.address, hubPool.address];
  await deployNewProxy("Scroll_SpokePool", {
    constructorArgs: [L2_ADDRESS_MAP[chainId].l2Weth, 3600, 32400],
    initializeFn: "__SpokePool_init",
    initializeArgs: initArgs,
  });
};
module.exports = func;
func.tags = ["ScrollSpokePool", "scroll"];
