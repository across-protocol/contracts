import { HardhatRuntimeEnvironment } from "hardhat/types";
import { DeployFunction } from "hardhat-deploy/types";
import { L1_ADDRESS_MAP, USDC, WETH } from "./consts";

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployer } = await hre.getNamedAccounts();
  const chainId = parseInt(await hre.getChainId());

  await hre.deployments.deploy("OP_Adapter", {
    from: deployer,
    log: true,
    skipIfAlreadyDeployed: true,
    args: [
      WETH[chainId],
      USDC[chainId],
      L1_ADDRESS_MAP[chainId].superseedCrossDomainMessenger,
      L1_ADDRESS_MAP[chainId].superseedStandardBridge,
      L1_ADDRESS_MAP[chainId].superseedOpUSDCBridge,
    ],
  });
};

module.exports = func;
func.tags = ["SuperseedAdapter", "mainnet"];
