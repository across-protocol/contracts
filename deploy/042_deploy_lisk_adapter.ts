import { L1_ADDRESS_MAP, USDC, WETH } from "./consts";
import { DeployFunction } from "hardhat-deploy/types";
import { HardhatRuntimeEnvironment } from "hardhat/types";

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployer } = await hre.getNamedAccounts();
  const chainId = parseInt(await hre.getChainId());

  await hre.deployments.deploy("Lisk_Adapter", {
    from: deployer,
    log: true,
    skipIfAlreadyDeployed: true,
    args: [
      WETH[chainId],
      L1_ADDRESS_MAP[chainId].liskCrossDomainMessenger,
      L1_ADDRESS_MAP[chainId].liskStandardBridge,
      USDC[chainId],
    ],
  });
};

module.exports = func;
func.tags = ["LiskAdapter", "mainnet"];
