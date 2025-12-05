import { DeployFunction } from "hardhat-deploy/types";
import { HardhatRuntimeEnvironment } from "hardhat/types";
import { deployNewProxy, getSpokePoolDeploymentInfo } from "../utils/utils.hre";
import { FILL_DEADLINE_BUFFER, L2_ADDRESS_MAP, QUOTE_TIME_BUFFER, USDC, ZERO_ADDRESS } from "./consts";
import { CHAIN_IDs, PRODUCTION_NETWORKS, TOKEN_SYMBOLS_MAP } from "../utils/constants";
import { getOftEid, toWei } from "../utils/utils";
import { getDeployedAddress } from "../src/DeploymentUtils";
import "@nomiclabs/hardhat-ethers";

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { hubPool, hubChainId, spokeChainId } = await getSpokePoolDeploymentInfo(hre);
  if (spokeChainId == CHAIN_IDs.BSC) {
    console.log("For BSC deployment to work, `hardhat.config.ts` might need a tweak");
    // Set these in hardhat.config.ts networks.bsc
    // gas: "auto",
    // gasPrice: 3e8, // 0.3 GWEI
    // gasMultiplier: 4.0,
  }

  const initArgs = [1, hubPool.address, hubPool.address];

  // Get Wrapped native token address:
  const nativeTokenSymbol = PRODUCTION_NETWORKS[spokeChainId].nativeToken;
  const wrappedPrefix = "W";
  const wrappedNativeSymbol = `${wrappedPrefix}${nativeTokenSymbol}`;
  const expectedWrappedNative = TOKEN_SYMBOLS_MAP[wrappedNativeSymbol].addresses[spokeChainId];
  if (!expectedWrappedNative) {
    throw new Error(`Wrapped native token not found for ${wrappedNativeSymbol} on chainId ${spokeChainId}`);
  }

  const oftEid = getOftEid(hubChainId);
  // ! Notice. Deployer has to adjust this fee cap based on dst chain's native token. 4.4 BNB for BSC
  let oftFeeCap = toWei("1"); // 1 ETH fee cap
  switch (spokeChainId) {
    case CHAIN_IDs.MONAD:
      oftFeeCap = toWei(78_000); // ~1 ETH fee cap
      break;
    case CHAIN_IDs.BSC:
      oftFeeCap = toWei(4.4); // ~1 ETH fee cap
      break;
    case CHAIN_IDs.HYPEREVM:
      oftFeeCap = toWei(100); // ~1ETH fee cap
      break;
  }

  const heliosAddress = getDeployedAddress("Helios", spokeChainId);

  const constructorArgs = [
    24 * 60 * 60, // 1 day; Helios latest head timestamp must be 1 day old before an admin can force execute a message.
    heliosAddress,
    getDeployedAddress("HubPoolStore", hubChainId),
    expectedWrappedNative,
    QUOTE_TIME_BUFFER,
    FILL_DEADLINE_BUFFER,
    USDC[spokeChainId] ?? ZERO_ADDRESS,
    // ! Notice: pick `cctpV2TokenMessenger` / `cctpTokenMessenger` here to match your adapter CCTP version
    L2_ADDRESS_MAP[spokeChainId]?.cctpV2TokenMessenger ?? ZERO_ADDRESS,
    oftEid,
    oftFeeCap,
  ];
  console.log(`Deploying new Universal SpokePool on ${spokeChainId} with constructor arguments:`, constructorArgs);
  console.log(`Deploying implementation with initialization arguments:`, initArgs);

  // @dev Deploy on different address for each chain.
  // The Universal Adapter writes calldata to be relayed to L2 by associating it with the
  // target address of the spoke pool. This is because the HubPool does not pass in the chainId when calling
  // relayMessage() on the Adapter. Therefore, if Universal SpokePools share the same address,
  // then a message designed to be sent to one chain could be sent to another's SpokePool.
  const { proxyAddress } = await deployNewProxy("Universal_SpokePool", constructorArgs, initArgs);

  if (!proxyAddress) {
    return;
  }

  console.log(`Deployed Universal SpokePool at ${proxyAddress}! Remember to transfer ownership to the Gnosis Safe!`);
};
module.exports = func;
func.tags = ["UniversalSpokePool"];
