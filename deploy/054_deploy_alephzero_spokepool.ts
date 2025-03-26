import { DeployFunction } from "hardhat-deploy/types";
import { HardhatRuntimeEnvironment } from "hardhat/types";
import { deployNewProxy, getSpokePoolDeploymentInfo } from "../utils/utils.hre";
import { FILL_DEADLINE_BUFFER, L2_ADDRESS_MAP, QUOTE_TIME_BUFFER, WAZERO, ZERO_ADDRESS } from "./consts";
import { BigNumber } from "ethers";

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { hubPool, spokeChainId } = await getSpokePoolDeploymentInfo(hre);

  const initArgs = [
    0,
    L2_ADDRESS_MAP[spokeChainId].l2GatewayRouter,
    // Set hub pool as cross domain admin since it delegatecalls the Adapter logic.
    hubPool.address,
    hubPool.address,
  ];

  const _bnZero = BigNumber.from(0);

  const constructorArgs = [
    WAZERO[spokeChainId],
    QUOTE_TIME_BUFFER,
    FILL_DEADLINE_BUFFER,
    ZERO_ADDRESS, // _l2Usdc
    // L2_ADDRESS_MAP[spokeChainId].cctpTokenMessenger,
    // For now, we are not using the CCTP bridge and can disable by setting
    // the cctpTokenMessenger to the zero address.
    ZERO_ADDRESS, // _cctpTokenMessenger
    // not using oft and hyperlane xerc20
    0, // _oftDstEid
    _bnZero, // _oftFeeCap
    0, // _hypXERC20DstDomain
    _bnZero, // _hyperlaneXERC20FeeCap
  ];
  await deployNewProxy("AlephZero_SpokePool", constructorArgs, initArgs);
};
module.exports = func;
func.tags = ["AlephZeroSpokePool", "alephzero"];
