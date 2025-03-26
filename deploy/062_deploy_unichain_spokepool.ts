import { DeployFunction } from "hardhat-deploy/types";
import { HardhatRuntimeEnvironment } from "hardhat/types";
import { deployNewProxy, getSpokePoolDeploymentInfo } from "../utils/utils.hre";
import { FILL_DEADLINE_BUFFER, L2_ADDRESS_MAP, QUOTE_TIME_BUFFER, USDC, WETH } from "./consts";
import { getHyperlaneDomainId, toWei } from "../utils/utils";
import { CHAIN_IDs } from "@across-protocol/constants";

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
    USDC[spokeChainId],
    L2_ADDRESS_MAP[spokeChainId].cctpTokenMessenger,
    hyperlaneDstDomainId,
    hyperlaneXERC20FeeCap,
  ];
  await deployNewProxy("DoctorWho_SpokePool", constructorArgs, initArgs);
};
module.exports = func;
func.tags = ["DoctorWhoSpokePool", "doctorwho"];
