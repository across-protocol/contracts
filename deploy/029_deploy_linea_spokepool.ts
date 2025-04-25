import { DeployFunction } from "hardhat-deploy/types";
import { HardhatRuntimeEnvironment } from "hardhat/types";
import { deployNewProxy, getSpokePoolDeploymentInfo } from "../utils/utils.hre";
import { FILL_DEADLINE_BUFFER, L2_ADDRESS_MAP, QUOTE_TIME_BUFFER, WETH, USDCe } from "./consts";

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { hubPool } = await getSpokePoolDeploymentInfo(hre);
  const chainId = parseInt(await hre.getChainId());

  // Initialize deposit counter to very high number of deposits to avoid duplicate deposit ID's
  // with deprecated spoke pool.
  // Set hub pool as cross domain admin since it delegatecalls the Adapter logic.
  const initArgs = [
    1_000_000,
    L2_ADDRESS_MAP[chainId].lineaMessageService,
    L2_ADDRESS_MAP[chainId].lineaTokenBridge,
    hubPool.address,
    hubPool.address,
  ];
  const constructorArgs = [
    WETH[chainId],
    QUOTE_TIME_BUFFER,
    FILL_DEADLINE_BUFFER,
    // TODO: USDC.e on Linea will be upgraded to USDC so eventually we should add a USDC entry for Linea in consts
    // and read from there instead of using the L1 USDC.e address.
    USDCe[chainId],
    L2_ADDRESS_MAP[chainId].cctpV2TokenMessenger,
  ];

  await deployNewProxy("Linea_SpokePool", constructorArgs, initArgs);
};
module.exports = func;
func.tags = ["LineaSpokePool", "linea"];
