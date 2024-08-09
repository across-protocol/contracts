import { DeployFunction } from "hardhat-deploy/types";
import { L2_ADDRESS_MAP } from "./consts";
import { deployNewProxy, getSpokePoolDeploymentInfo } from "../utils/utils.hre";
import { HardhatRuntimeEnvironment } from "hardhat/types";

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { hubPool, spokeChainId } = await getSpokePoolDeploymentInfo(hre);

  const initArgs = [
    // Initialize deposit counter to very high number of deposits to avoid duplicate deposit ID's
    // with deprecated spoke pool.
    1_000_000,
    L2_ADDRESS_MAP[spokeChainId].l2GatewayRouter,
    // Set hub pool as cross domain admin since it delegatecalls the Adapter logic.
    hubPool.address,
    hubPool.address,
  ];

  // Construct this spokepool with a:
  //    * A WETH address of the WETH address
  //    * A depositQuoteTimeBuffer of 1 hour
  //    * A fillDeadlineBuffer of 6 hours
  //    * Native USDC address on L2
  //    * CCTP token messenger address on L2
  const constructorArgs = [
    L2_ADDRESS_MAP[spokeChainId].l2Weth,
    3600,
    21600,
    L2_ADDRESS_MAP[spokeChainId].l2Usdc,
    L2_ADDRESS_MAP[spokeChainId].cctpTokenMessenger,
  ];
  await deployNewProxy("Arbitrum_SpokePool", constructorArgs, initArgs);
};
module.exports = func;
func.tags = ["ArbitrumSpokePool", "arbitrum"];
