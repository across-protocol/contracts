import { HardhatRuntimeEnvironment } from "hardhat/types";
import { DeployFunction } from "hardhat-deploy/types";
import { deployNewProxy, getSpokePoolDeploymentInfo } from "../utils/utils.hre";
import { FILL_DEADLINE_BUFFER, L2_ADDRESS_MAP, QUOTE_TIME_BUFFER, WETH } from "./consts";

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { getChainId } = hre;
  const { hubPool } = await getSpokePoolDeploymentInfo(hre);
  const chainId = parseInt(await getChainId());

  // Initialize deposit counter to very high number of deposits to avoid duplicate deposit ID's
  // with deprecated spoke pool.
  // Set hub pool as cross domain admin since it delegatecalls the Adapter logic.
  const initArgs = [
    L2_ADDRESS_MAP[chainId].scrollERC20GatewayRouter,
    L2_ADDRESS_MAP[chainId].scrollMessenger,
    1_000_000,
    hubPool.address,
    hubPool.address,
  ];
  const constructorArgs = [WETH[chainId], QUOTE_TIME_BUFFER, FILL_DEADLINE_BUFFER];

  await deployNewProxy("Scroll_SpokePool", constructorArgs, initArgs);
};
module.exports = func;
func.tags = ["ScrollSpokePool", "scroll"];
