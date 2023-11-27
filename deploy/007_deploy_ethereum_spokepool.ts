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
  const constructorArgs = [1_000_000, hubPool.address, L1_ADDRESS_MAP[chainId].weth];
  await deployNewProxy("Ethereum_SpokePool", constructorArgs, {
    constructorArgs: [L1_ADDRESS_MAP[chainId].weth],
  });

  // Transfer ownership to hub pool.
};
module.exports = func;
func.tags = ["EthereumSpokePool", "mainnet"];
