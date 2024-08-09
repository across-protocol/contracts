import { HardhatRuntimeEnvironment } from "hardhat/types";
import { DeployFunction } from "hardhat-deploy/types";
import { deployNewProxy, getSpokePoolDeploymentInfo } from "../utils/utils.hre";
import { FILL_DEADLINE_BUFFER, QUOTE_TIME_BUFFER, WETH } from "./consts";

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { hubPool, spokeChainId } = await getSpokePoolDeploymentInfo(hre);
  console.log(`Using HubPool @ ${hubPool.address}`);

  // Initialize deposit counter to very high number of deposits to avoid duplicate deposit ID's
  // with deprecated spoke pool.
  const initArgs = [1_000_000, hubPool.address];

  const constructorArgs = [WETH[spokeChainId], QUOTE_TIME_BUFFER, FILL_DEADLINE_BUFFER];
  await deployNewProxy("Ethereum_SpokePool", constructorArgs, initArgs);

  // Transfer ownership to hub pool.
};
module.exports = func;
func.tags = ["EthereumSpokePool", "mainnet"];
