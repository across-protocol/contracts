import "hardhat-deploy";
import hre from "hardhat";
import { L2_ADDRESS_MAP } from "./consts";
import { deployNewProxy } from "../utils";

const func = async function () {
  const hubPool = await hre.companionNetworks.l1.deployments.get("HubPool");
  const chainId = await hre.getChainId();
  console.log(`Using L1 (chainId ${chainId}) hub pool @ ${hubPool.address}`);

  // Set hub pool as cross domain admin since it delegatecalls the Adapter logic.
  const constructorArgs = [
    0, // Start at 0 since this first time we're deploying this spoke pool. On future upgrades increase this.
    L2_ADDRESS_MAP[chainId].zkErc20Bridge,
    L2_ADDRESS_MAP[chainId].zkEthBridge,
    hubPool.address,
    hubPool.address,
    L2_ADDRESS_MAP[chainId].l2Weth,
  ];
  await deployNewProxy("ZkSync_SpokePool", constructorArgs);
};
module.exports = func;
func.tags = ["ZkSyncSpokePool", "zksync"];
