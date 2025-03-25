import { DeployFunction } from "hardhat-deploy/types";
import { HardhatRuntimeEnvironment } from "hardhat/types";
import { deployNewProxy, getSpokePoolDeploymentInfo } from "../utils/utils.hre";
import { FILL_DEADLINE_BUFFER, QUOTE_TIME_BUFFER } from "./consts";
import { toWei } from "../utils/utils";
import { CHAIN_IDs } from "@across-protocol/constants";

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { hubPool, hubChainId } = await getSpokePoolDeploymentInfo(hre);

  // Set the Hyperlane xERC20 destination domain based on the chain
  // https://github.com/hyperlane-xyz/hyperlane-registry/tree/main/chains
  const hypXERC20DstDomain = hubChainId == CHAIN_IDs.MAINNET ? 1 : 11155111;

  // 1 ETH fee cap for Hyperlane XERC20 transfers
  const hypXERC20FeeCap = toWei(1);

  // Initialize deposit counter to very high number of deposits to avoid duplicate deposit ID's
  // with deprecated spoke pool.
  // Set hub pool as cross domain admin since it delegatecalls the Adapter logic.
  const initArgs = [1_000_000, hubPool.address, hubPool.address];

  const constructorArgs = [
    "0xDeadDeAddeAddEAddeadDEaDDEAdDeaDDeAD0000",
    QUOTE_TIME_BUFFER,
    FILL_DEADLINE_BUFFER,
    hypXERC20DstDomain,
    hypXERC20FeeCap,
  ];
  await deployNewProxy("Boba_SpokePool", constructorArgs, initArgs);
};
module.exports = func;
func.tags = ["BobaSpokePool", "boba"];
