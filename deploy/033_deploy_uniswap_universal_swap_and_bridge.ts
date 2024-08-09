import { DeployFunction } from "hardhat-deploy/types";
import { HardhatRuntimeEnvironment } from "hardhat/types";

import { getDeployedAddress } from "../src/DeploymentUtils";
import { L2_ADDRESS_MAP } from "./consts";

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployments: { deploy }, getChainId, getNamedAccounts } = hre;
  const { deployer } = await getNamedAccounts();
  const chainId = parseInt(await getChainId());

  await deploy("UniswapV3_UniversalSwapAndBridge", {
    contract: "UniversalSwapAndBridge",
    from: deployer,
    log: true,
    skipIfAlreadyDeployed: true,
    args: [
      getDeployedAddress("SpokePool", chainId),
      L2_ADDRESS_MAP[chainId].uniswapV3SwapRouter,
      // Function selector for `exactInputSingle` method in Uniswap V3 SwapRouter
      // https://etherscan.io/address/0xE592427A0AEce92De3Edee1F18E0157C05861564#writeProxyContract#F2
      ["0x414bf389"],
    ],
  });
};
module.exports = func;
func.tags = ["UniswapV3_UniversalSwapAndBridge", "UniversalSwapAndBridge", "uniswapV3"];
