import { DeployFunction } from "hardhat-deploy/types";
import { HardhatRuntimeEnvironment } from "hardhat/types";
import { deployNewProxy, getSpokePoolDeploymentInfo } from "../utils/utils.hre";
import {
  FILL_DEADLINE_BUFFER,
  L1_ADDRESS_MAP,
  L2_ADDRESS_MAP,
  QUOTE_TIME_BUFFER,
  WETH,
  USDC,
  ZERO_ADDRESS,
} from "./consts";
import { CHAIN_IDs } from "../utils/constants";

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { hubPool, spokeChainId } = await getSpokePoolDeploymentInfo(hre);

  const initArgs = [1, hubPool.address, hubPool.address];
  // @todo replace the ?? ZERO_ADDRESS below before using this script.
  const constructorArgs = [
    24 * 60 * 60, // 1 day; Helios latest head timestamp must be 1 day old before an admin can force execute a message.
    L2_ADDRESS_MAP[spokeChainId]?.helios ?? ZERO_ADDRESS,
    L1_ADDRESS_MAP[CHAIN_IDs.MAINNET]?.hubPoolStore ?? ZERO_ADDRESS,
    WETH[spokeChainId],
    QUOTE_TIME_BUFFER,
    FILL_DEADLINE_BUFFER,
    USDC[spokeChainId] ?? ZERO_ADDRESS,
    L2_ADDRESS_MAP[spokeChainId]?.cctpTokenMessenger ?? ZERO_ADDRESS,
  ];

  // @dev Deploy on different address for each chain.
  // The Universal Adapter writes calldata to be relayed to L2 by associating it with the
  // target address of the spoke pool. This is because the HubPool does not pass in the chainId when calling
  // relayMessage() on the Adapter. Therefore, if Universal SpokePools share the same address,
  // then a message designed to be sent to one chain could be sent to another's SpokePool.
  await deployNewProxy("Universal_SpokePool", constructorArgs, initArgs);
};
module.exports = func;
func.tags = ["UniversalSpokePool"];
