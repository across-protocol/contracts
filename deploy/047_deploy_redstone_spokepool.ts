import { DeployFunction } from "hardhat-deploy/types";
import { HardhatRuntimeEnvironment } from "hardhat/types";
import { deployNewProxy, getSpokePoolDeploymentInfo } from "../utils/utils.hre";
import { FILL_DEADLINE_BUFFER, WETH, QUOTE_TIME_BUFFER, ZERO_ADDRESS } from "./consts";
import { toWei } from "../utils/utils";
import { CHAIN_IDs } from "@across-protocol/constants";

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { hubPool, spokeChainId, hubChainId } = await getSpokePoolDeploymentInfo(hre);

  const initArgs = [
    1,
    // Set hub pool as cross domain admin since it delegatecalls the Adapter logic.
    hubPool.address,
    hubPool.address,
  ];

  // Set the Hyperlane xERC20 destination domain based on the chain
  // https://github.com/hyperlane-xyz/hyperlane-registry/tree/main/chains
  const hypXERC20DstDomain = hubChainId == CHAIN_IDs.MAINNET ? 1 : 11155111;

  // 1 ETH fee cap for Hyperlane XERC20 transfers
  const hypXERC20FeeCap = toWei(1);

  const constructorArgs = [
    WETH[spokeChainId],
    QUOTE_TIME_BUFFER,
    FILL_DEADLINE_BUFFER,
    ZERO_ADDRESS,
    // L2_ADDRESS_MAP[spokeChainId].cctpTokenMessenger,
    // For now, we are not using the CCTP bridge and can disable by setting
    // the cctpTokenMessenger to the zero address.
    ZERO_ADDRESS,
    hypXERC20DstDomain,
    hypXERC20FeeCap,
  ];
  await deployNewProxy("Redstone_SpokePool", constructorArgs, initArgs);
};
module.exports = func;
func.tags = ["RedstoneSpokePool", "redstone"];
