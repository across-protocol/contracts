import { DeployFunction } from "hardhat-deploy/types";
import { HardhatRuntimeEnvironment } from "hardhat/types";
import { WETH } from "./consts";

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployer } = await hre.getNamedAccounts();
  const chainId = parseInt(await hre.getChainId());

  await hre.deployments.deploy("ZkSync_Adapter", {
    from: deployer,
    log: true,
    skipIfAlreadyDeployed: true,
    // Most common across dataworker set as the refund address, but changeable by whoever runs the script.
    args: [WETH[chainId], "0x07aE8551Be970cB1cCa11Dd7a11F47Ae82e70E67"],
  });
};

module.exports = func;
func.tags = ["ZkSyncAdapter", "mainnet"];
