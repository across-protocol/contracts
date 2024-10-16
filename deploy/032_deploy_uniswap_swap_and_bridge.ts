import { DeployFunction } from "hardhat-deploy/types";
import { HardhatRuntimeEnvironment } from "hardhat/types";
import { getDeployedAddress } from "../src/DeploymentUtils";
import { CHAIN_IDs, TOKEN_SYMBOLS_MAP } from "../utils";
import { L2_ADDRESS_MAP } from "./consts";

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { BASE } = CHAIN_IDs;
  const { deployer } = await hre.getNamedAccounts();
  const chainId = parseInt(await hre.getChainId());

  await hre.deployments.deploy("UniswapV3_SwapAndBridge", {
    contract: "SwapAndBridge",
    from: deployer,
    log: true,
    skipIfAlreadyDeployed: true,
    args: [
      getDeployedAddress("SpokePool", chainId),
      L2_ADDRESS_MAP[chainId].uniswapV3SwapRouter,
      // Function selector for `exactInputSingle` method in Uniswap V3 SwapRouter
      // https://etherscan.io/address/0xE592427A0AEce92De3Edee1F18E0157C05861564#writeProxyContract#F2
      ["0x414bf389"],
      TOKEN_SYMBOLS_MAP[chainId === BASE ? "USDbC" : "USDC.e"].addresses[chainId],
      TOKEN_SYMBOLS_MAP.USDC.addresses[chainId],
    ],
  });
};
module.exports = func;
func.tags = ["UniswapV3_SwapAndBridge", "SwapAndBridge", "uniswapV3"];
