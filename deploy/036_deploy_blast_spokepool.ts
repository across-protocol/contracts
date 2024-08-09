import { DeployFunction } from "hardhat-deploy/types";
import { HardhatRuntimeEnvironment } from "hardhat/types";
import { deployNewProxy, getSpokePoolDeploymentInfo } from "../utils/utils.hre";
import { WETH, ZERO_ADDRESS } from "./consts";

const USDB = TOKEN_SYMBOLS_MAP.USDB.addresses;

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { hubPool, spokeChainId, hubChainId } = await getSpokePoolDeploymentInfo(hre);

  const initArgs = [
    // Initialize deposit counter to very high number of deposits to avoid duplicate deposit ID's
    // with deprecated spoke pool.
    1_000_000,
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
    WETH[spokeChainId],
    3600,
    21600,
    ZERO_ADDRESS,
    // L2_ADDRESS_MAP[spokeChainId].cctpTokenMessenger,
    // For now, we are not using the CCTP bridge and can disable by setting
    // the cctpTokenMessenger to the zero address.
    ZERO_ADDRESS,
    USDB[spokeChainId],
    USDB[hubChainId],
    "0x8bA929bE3462a809AFB3Bf9e100Ee110D2CFE531",
    L1_ADDRESS_MAP[hubChainId].blastDaiRetriever, // Address of mainnet retriever contract to facilitate USDB finalizations.
  ];
  await deployNewProxy("Blast_SpokePool", constructorArgs, initArgs);
};
module.exports = func;
func.tags = ["BlastSpokePool", "blast"];
