import { DeployFunction } from "hardhat-deploy/types";
import { HardhatRuntimeEnvironment } from "hardhat/types";
import { deployNewProxy, getSpokePoolDeploymentInfo } from "../utils/utils.hre";
import { FILL_DEADLINE_BUFFER, WETH, QUOTE_TIME_BUFFER, ZERO_ADDRESS } from "./consts";
import { getHyperlaneDomainId, toWei } from "../utils/utils";

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { hubPool, spokeChainId, hubChainId } = await getSpokePoolDeploymentInfo(hre);

  const initArgs = [
    1,
    // Set hub pool as cross domain admin since it delegatecalls the Adapter logic.
    hubPool.address,
    hubPool.address,
  ];

  const hyperlaneDstDomainId = getHyperlaneDomainId(hubChainId);
  const hyperlaneXERC20FeeCap = toWei(1); // 1 eth fee cap

  const constructorArgs = [
    WETH[spokeChainId],
    QUOTE_TIME_BUFFER,
    FILL_DEADLINE_BUFFER,
    ZERO_ADDRESS,
    // L2_ADDRESS_MAP[spokeChainId].cctpTokenMessenger,
    // For now, we are not using the CCTP bridge and can disable by setting
    // the cctpTokenMessenger to the zero address.
    ZERO_ADDRESS,
    hyperlaneDstDomainId,
    hyperlaneXERC20FeeCap,
  ];
  await deployNewProxy("Mode_SpokePool", constructorArgs, initArgs);
};
module.exports = func;
func.tags = ["ModeSpokePool", "mode"];
