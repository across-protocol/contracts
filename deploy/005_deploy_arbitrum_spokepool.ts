import { DeployFunction } from "hardhat-deploy/types";
import { L2_ADDRESS_MAP } from "./consts";
import { deployNewProxy } from "../utils";
import { HardhatRuntimeEnvironment } from "hardhat/types";

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const hubPool = await hre.companionNetworks.l1.deployments.get("HubPool");
  const chainId = await hre.getChainId();
  console.log(`Using L1 (chainId ${chainId}) hub pool @ ${hubPool.address}`);

  // Initialize deposit counter to very high number of deposits to avoid duplicate deposit ID's
  // with deprecated spoke pool.
  // Set hub pool as cross domain admin since it delegatecalls the Adapter logic.
  const constructorArgs = [
    1_000_000,
    L2_ADDRESS_MAP[chainId].l2GatewayRouter,
    hubPool.address,
    hubPool.address,
    L2_ADDRESS_MAP[chainId].l2Weth,
  ];
  await deployNewProxy("Arbitrum_SpokePool", constructorArgs);
};
module.exports = func;
func.tags = ["ArbitrumSpokePool", "arbitrum"];
