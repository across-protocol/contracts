import { DeployFunction } from "hardhat-deploy/types";
import { HardhatRuntimeEnvironment } from "hardhat/types";
import { deployNewProxy, getSpokePoolDeploymentInfo } from "../utils/utils.hre";
import { FILL_DEADLINE_BUFFER, L1_ADDRESS_MAP, L2_ADDRESS_MAP, QUOTE_TIME_BUFFER, USDC, ZERO_ADDRESS } from "./consts";
import { CHAIN_IDs, PRODUCTION_NETWORKS, TOKEN_SYMBOLS_MAP } from "../utils/constants";

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { hubPool, spokeChainId } = await getSpokePoolDeploymentInfo(hre);

  const initArgs = [1, hubPool.address, hubPool.address];

  // Get Wrapped native token address:
  const nativeTokenSymbol = PRODUCTION_NETWORKS[spokeChainId].nativeToken;
  const wrappedPrefix = "W";
  const wrappedNativeSymbol = `${wrappedPrefix}${nativeTokenSymbol}`;
  const expectedWrappedNative = TOKEN_SYMBOLS_MAP[wrappedNativeSymbol].addresses[spokeChainId];
  if (!expectedWrappedNative) {
    throw new Error(`Wrapped native token not found for ${wrappedNativeSymbol} on chainId ${spokeChainId}`);
  }

  const constructorArgs = [
    24 * 60 * 60, // 1 day; Helios latest head timestamp must be 1 day old before an admin can force execute a message.
    L2_ADDRESS_MAP[spokeChainId]?.helios,
    L1_ADDRESS_MAP[CHAIN_IDs.MAINNET]?.hubPoolStore,
    expectedWrappedNative,
    QUOTE_TIME_BUFFER,
    FILL_DEADLINE_BUFFER,
    USDC[spokeChainId] ?? ZERO_ADDRESS,
    L2_ADDRESS_MAP[spokeChainId]?.cctpTokenMessenger ?? ZERO_ADDRESS,
  ];
  console.log(`Deploying new Universal SpokePool on ${spokeChainId} with args:`, constructorArgs);

  // @dev Deploy on different address for each chain.
  // The Universal Adapter writes calldata to be relayed to L2 by associating it with the
  // target address of the spoke pool. This is because the HubPool does not pass in the chainId when calling
  // relayMessage() on the Adapter. Therefore, if Universal SpokePools share the same address,
  // then a message designed to be sent to one chain could be sent to another's SpokePool.
  await deployNewProxy("Universal_SpokePool", constructorArgs, initArgs);
};
module.exports = func;
func.tags = ["UniversalSpokePool"];
