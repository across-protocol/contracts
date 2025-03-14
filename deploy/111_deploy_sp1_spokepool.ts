import { DeployFunction } from "hardhat-deploy/types";
import { HardhatRuntimeEnvironment } from "hardhat/types";
import { deployNewProxy, getSpokePoolDeploymentInfo } from "../utils/utils.hre";
import { FILL_DEADLINE_BUFFER, L1_ADDRESS_MAP, L2_ADDRESS_MAP, QUOTE_TIME_BUFFER, WETH } from "./consts";
import { CHAIN_IDs } from "../utils/constants";

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { hubPool, spokeChainId } = await getSpokePoolDeploymentInfo(hre);

  const initArgs = [1, hubPool.address, hubPool.address];
  const constructorArgs = [
    L2_ADDRESS_MAP[spokeChainId].sp1Verifier,
    L2_ADDRESS_MAP[spokeChainId].helios,
    "1234", // across SP1 program key
    L1_ADDRESS_MAP[CHAIN_IDs.MAINNET].hubPoolStore,
    WETH[spokeChainId],
    QUOTE_TIME_BUFFER,
    FILL_DEADLINE_BUFFER,
  ];

  // @dev DO NOT DEPLOY using create2. The SP1 Adapter writes calldata to be relayed to L2 by associating it with the
  // target address of the spoke pool. This is because the HubPool does not pass in the chainId when calling
  // relayMessage() on the Adapter. Therefore, if SP1_SpokePools share the same address, then a message designed to be
  // sent to one chain could be sent to another's SpokePool.
  await deployNewProxy("SP1_SpokePool", constructorArgs, initArgs);
};
module.exports = func;
func.tags = ["SP1SpokePool", "sp1"];
