import { DeployFunction } from "hardhat-deploy/types";
import { HardhatRuntimeEnvironment } from "hardhat/types";
import { deployNewProxy, getSpokePoolDeploymentInfo } from "../utils/utils.hre";
import { FILL_DEADLINE_BUFFER, L2_ADDRESS_MAP, QUOTE_TIME_BUFFER, USDC, WETH } from "./consts";
import { toWei } from "../utils/utils";
import { CHAIN_IDs } from "@across-protocol/constants";

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { hubPool, spokeChainId, hubChainId } = await getSpokePoolDeploymentInfo(hre);

  const initArgs = [
    // Initialize deposit counter to very high number of deposits to avoid duplicate deposit ID's
    // with deprecated spoke pool.
    1_000_000,
    L2_ADDRESS_MAP[spokeChainId].l2GatewayRouter,
    // Set hub pool as cross domain admin since it delegatecalls the Adapter logic.
    hubPool.address,
    hubPool.address,
  ];

  // Set the Hyperlane xERC20 destination domain based on the chain
  // https://github.com/hyperlane-xyz/hyperlane-registry/tree/main/chains
  const oftArbitrumEid = hubChainId == CHAIN_IDs.MAINNET ? 30101 : 40161;

  // 1 ETH fee cap for OFT transfers
  const oftFeeCap = toWei(1);

  // Set the Hyperlane xERC20 destination domain based on the chain
  // https://github.com/hyperlane-xyz/hyperlane-registry/tree/main/chains
  const hypXERC20DstDomain = hubChainId == CHAIN_IDs.MAINNET ? 1 : 11155111;

  // 1 ETH fee cap for Hyperlane XERC20 transfers
  const hypXERC20FeeCap = toWei(1);

  const constructorArgs = [
    WETH[spokeChainId],
    QUOTE_TIME_BUFFER,
    FILL_DEADLINE_BUFFER,
    USDC[spokeChainId],
    L2_ADDRESS_MAP[spokeChainId].cctpTokenMessenger,
    oftArbitrumEid,
    oftFeeCap,
    hypXERC20DstDomain,
    hypXERC20FeeCap,
  ];
  await deployNewProxy("Arbitrum_SpokePool", constructorArgs, initArgs);
};
module.exports = func;
func.tags = ["ArbitrumSpokePool", "arbitrum"];
