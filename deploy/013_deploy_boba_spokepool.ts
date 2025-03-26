import { DeployFunction } from "hardhat-deploy/types";
import { HardhatRuntimeEnvironment } from "hardhat/types";
import { deployNewProxy, getSpokePoolDeploymentInfo } from "../utils/utils.hre";
import { FILL_DEADLINE_BUFFER, QUOTE_TIME_BUFFER } from "./consts";
import { getHyperlaneDomainId, toWei } from "../utils/utils";

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { hubPool, hubChainId } = await getSpokePoolDeploymentInfo(hre);

  const hyperlaneDstDomainId = getHyperlaneDomainId(hubChainId);
  const hyperlaneXERC20FeeCap = toWei(1); // 1 eth fee cap

  // Initialize deposit counter to very high number of deposits to avoid duplicate deposit ID's
  // with deprecated spoke pool.
  // Set hub pool as cross domain admin since it delegatecalls the Adapter logic.
  const initArgs = [1_000_000, hubPool.address, hubPool.address];

  const constructorArgs = [
    "0xDeadDeAddeAddEAddeadDEaDDEAdDeaDDeAD0000",
    QUOTE_TIME_BUFFER,
    FILL_DEADLINE_BUFFER,
    hyperlaneDstDomainId,
    hyperlaneXERC20FeeCap,
  ];
  await deployNewProxy("Boba_SpokePool", constructorArgs, initArgs);
};
module.exports = func;
func.tags = ["BobaSpokePool", "boba"];
