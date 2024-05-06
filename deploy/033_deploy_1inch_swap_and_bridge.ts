import { DeployFunction } from "hardhat-deploy/types";
import { HardhatRuntimeEnvironment } from "hardhat/types";

import { getDeployedAddress } from "../src/DeploymentUtils";
import { L2_ADDRESS_MAP } from "./consts";

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { getChainId, deployments, getNamedAccounts } = hre;
  const { deploy } = deployments;

  const chainId = parseInt(await getChainId());
  const { deployer } = await getNamedAccounts();

  await deploy("1inch_UniversalSwapAndBridge", {
    contract: "UniversalSwapAndBridge",
    from: deployer,
    log: true,
    skipIfAlreadyDeployed: true,
    args: [
      getDeployedAddress("SpokePool", chainId),
      L2_ADDRESS_MAP[chainId]["1inchV6Router"],
      // Function selectors for all relevant swap-methods in 1inch V6 AggregationRouter
      // See: https://etherscan.io/address/0x111111125421ca6dc452d289314280a0f8842a65#writeContract
      [
        "0xd2d374e5",
        "0xc4d652af",
        "0xe413f48d",
        "0x07ed2379",
        "0xfa461e33",
        "0x83800a8e",
        "0x8770ba91",
        "0x19367472",
        "0xe2c95c82",
        "0xea76dddf",
        "0xf7a70056",
      ],
    ],
  });
};
module.exports = func;
func.tags = ["1inch_UniversalSwapAndBridge", "UniversalSwapAndBridge", "1inch"];
