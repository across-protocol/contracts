import { L2_ADDRESS_MAP } from "./consts";
import { deployNewProxy, getSpokePoolDeploymentInfo } from "../utils/utils.hre";
import { DeployFunction } from "hardhat-deploy/types";
import { HardhatRuntimeEnvironment } from "hardhat/types";

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { getChainId } = hre;
  const { hubPool } = await getSpokePoolDeploymentInfo(hre);
  const chainId = parseInt(await getChainId());

  const initArgs = [
    L2_ADDRESS_MAP[chainId].polygonZkEvmBridge,
    // Initialize deposit counter to very high number of deposits to avoid duplicate deposit ID's
    // with deprecated spoke pool.
    1_000_000,
    // Set hub pool as cross domain admin since it delegatecalls the Adapter logic.
    hubPool.address,
    hubPool.address,
  ];
  const constructorArgs = [L2_ADDRESS_MAP[chainId].l2Weth, 3600, 32400];

  await deployNewProxy("PolygonZkEVM_SpokePool", constructorArgs, initArgs);
};
module.exports = func;
func.tags = ["PolygonZkEvmSpokePool", "polygonZkEvm"];
