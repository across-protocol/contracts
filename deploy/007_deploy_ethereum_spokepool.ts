import { DeployFunction } from "hardhat-deploy/types";
import { deployNewProxy } from "../utils/utils.hre";
import { L1_ADDRESS_MAP } from "./consts";
import { HardhatRuntimeEnvironment } from "hardhat/types";

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const hubPool = await hre.companionNetworks.l1.deployments.get("HubPool");
  const chainId = await hre.getChainId();
  console.log(`Using L1 (chainId ${chainId}) hub pool @ ${hubPool.address}`);

  // Initialize deposit counter to very high number of deposits to avoid duplicate deposit ID's
  // with deprecated spoke pool.
  const constructorArgs = [1_000_000, hubPool.address, L1_ADDRESS_MAP[chainId].weth];
  await deployNewProxy("Ethereum_SpokePool", constructorArgs);

  // Transfer ownership to hub pool.
};
module.exports = func;
func.tags = ["EthereumSpokePool", "mainnet"];
