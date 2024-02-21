import { DeployFunction } from "hardhat-deploy/types";
import { deployNewProxy } from "../utils/utils.hre";
import { L1_ADDRESS_MAP } from "./consts";
import { HardhatRuntimeEnvironment } from "hardhat/types";

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployments, getChainId } = hre;
  const chainId = await getChainId();
  const hubPool = await deployments.get("HubPool");
  console.log(`Using chain ${chainId} HubPool @ ${hubPool.address}`);

  // Initialize deposit counter to very high number of deposits to avoid duplicate deposit ID's
  // with deprecated spoke pool.
  const initArgs = [1_000_000, hubPool.address];

  // Construct this spokepool with a:
  //    * A WETH address of the WETH address
  //    * A depositQuoteTimeBuffer of 1 hour
  //    * A fillDeadlineBuffer of 8 hours
  const constructorArgs = [L1_ADDRESS_MAP[chainId].weth, 3600, 28800];
  await deployNewProxy("Ethereum_SpokePool", constructorArgs, initArgs, chainId === "1");

  // Transfer ownership to hub pool.
};
module.exports = func;
func.tags = ["EthereumSpokePool", "mainnet"];
