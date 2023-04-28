import { deployNewProxy } from "../utils";
import { DeployFunction } from "hardhat-deploy/types";

const func: DeployFunction = async function (hre: any) {
  const hubPool = await hre.companionNetworks.l1.deployments.get("HubPool");
  const chainId = await hre.getChainId();
  console.log(`Using L1 (chainId ${chainId}) hub pool @ ${hubPool.address}`);

  // Initialize deposit counter to very high number of deposits to avoid duplicate deposit ID's
  // with deprecated spoke pool.
  // Set hub pool as cross domain admin since it delegatecalls the Adapter logic.
  const constructorArgs = [1_000_000, hubPool.address, hubPool.address];
  await deployNewProxy("Optimism_SpokePool", constructorArgs);
};
module.exports = func;
func.tags = ["OptimismSpokePool", "optimism"];
