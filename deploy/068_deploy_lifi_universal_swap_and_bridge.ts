import { DeployFunction } from "hardhat-deploy/types";
import { HardhatRuntimeEnvironment } from "hardhat/types";

import { getDeployedAddress } from "../src/DeploymentUtils";
import { CHAIN_IDs } from "@across-protocol/constants";
import { L1_ADDRESS_MAP, L2_ADDRESS_MAP } from "./consts";

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployer } = await hre.getNamedAccounts();
  const chainId = parseInt(await hre.getChainId());

  await hre.deployments.deploy("LiFi_UniversalSwapAndBridge", {
    contract: "UniversalSwapAndBridge",
    from: deployer,
    log: true,
    skipIfAlreadyDeployed: false,
    deterministicDeployment: "0x123456789abc", // Salt for the create2 call.
    args: [
      getDeployedAddress("SpokePool", chainId),
      chainId === CHAIN_IDs.MAINNET ? L1_ADDRESS_MAP[chainId].lifiDiamond : L2_ADDRESS_MAP[chainId].lifiDiamond,
      // Allows swap function selectors in LiFi Diamond Proxy:
      // - swapTokensMultipleV3ERC20ToERC20 (0x5fd9ae2e)
      // - swapTokensMultipleV3ERC20ToNative (0x2c57e884)
      // - swapTokensMultipleV3NativeToERC20 (0x736eac0b)
      // - swapTokensSingleV3ERC20ToERC20 (0x4666fc80)
      // - swapTokensSingleV3ERC20ToNative (0x733214a3)
      // - swapTokensSingleV3NativeToERC20 (0xaf7060fd)
      // https://etherscan.io/address/0x1231DEB6f5749EF6cE6943a275A1D3E7486F4EaE#multipleProxyContract
      ["0x5fd9ae2e", "0x2c57e884", "0x736eac0b", "0x4666fc80", "0x733214a3", "0xaf7060fd"],
    ],
  });
};
module.exports = func;
func.tags = ["LiFi_UniversalSwapAndBridge", "UniversalSwapAndBridge", "lifi"];
