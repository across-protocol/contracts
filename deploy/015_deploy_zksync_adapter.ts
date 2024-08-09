import { DeployFunction } from "hardhat-deploy/types";
import { HardhatRuntimeEnvironment } from "hardhat/types";
import { WETH } from "./consts";

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const {
    deployments: { deploy },
    getNamedAccounts,
    getChainId,
  } = hre;
  const { deployer } = await getNamedAccounts();
  const chainId = parseInt(await getChainId());

  await deploy("ZkSync_Adapter", {
    from: deployer,
    log: true,
    skipIfAlreadyDeployed: true,
    // Most common across dataworker set as the refund address, but changeable by whoever runs the script.
    args: [WETH[chainId], "0x428AB2BA90Eba0a4Be7aF34C9Ac451ab061AC010"],
  });
};

module.exports = func;
func.tags = ["ZkSyncAdapter", "mainnet"];
