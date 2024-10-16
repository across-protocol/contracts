import { DeployFunction } from "hardhat-deploy/types";
import { HardhatRuntimeEnvironment } from "hardhat/types";
import { L1_ADDRESS_MAP, WETH, ZERO_ADDRESS } from "./consts";

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployer } = await hre.getNamedAccounts();
  const chainId = parseInt(await hre.getChainId());
  const lpTokenFactory = await hre.deployments.deploy("LpTokenFactory", {
    from: deployer,
    log: true,
    skipIfAlreadyDeployed: true,
  });

  await hre.deployments.deploy("HubPool", {
    from: deployer,
    log: true,
    skipIfAlreadyDeployed: true,
    args: [lpTokenFactory.address, L1_ADDRESS_MAP[chainId].finder, WETH[chainId], ZERO_ADDRESS],
    libraries: { MerkleLib: lpTokenFactory.address },
  });
};
module.exports = func;
func.tags = ["HubPool", "mainnet"];
