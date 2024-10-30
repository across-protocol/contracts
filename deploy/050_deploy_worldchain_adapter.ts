import { HardhatRuntimeEnvironment } from "hardhat/types";
import { DeployFunction } from "hardhat-deploy/types";
import { L1_ADDRESS_MAP, WETH, ZERO_ADDRESS } from "./consts";

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployer } = await hre.getNamedAccounts();
  const chainId = parseInt(await hre.getChainId());

  await hre.deployments.deploy("WorldChain_Adapter", {
    from: deployer,
    log: true,
    skipIfAlreadyDeployed: true,
    args: [
      WETH[chainId],
      L1_ADDRESS_MAP[chainId].worldChainCrossDomainMessenger,
      L1_ADDRESS_MAP[chainId].worldChainStandardBridge,
      ZERO_ADDRESS,
    ],
  });
};

module.exports = func;
func.tags = ["WorldChainAdapter", "mainnet"];
