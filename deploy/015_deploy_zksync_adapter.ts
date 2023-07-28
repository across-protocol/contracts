import { DeployFunction } from "hardhat-deploy/types";
import { HardhatRuntimeEnvironment } from "hardhat/types";
import { L1_ADDRESS_MAP } from "./consts";

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployments, getNamedAccounts, getChainId } = hre;

  const { deploy } = deployments;

  const { deployer } = await getNamedAccounts();
  const chainId = parseInt(await getChainId());

  // zkSync era contract address can be found at:
  // https://era.zksync.io/docs/dev/building-on-zksync/useful-address.html
  const { weth, zkSyncMailbox, zkSyncErc20Bridge } = L1_ADDRESS_MAP[chainId];

  await deploy("ZkSync_Adapter", {
    from: deployer,
    log: true,
    skipIfAlreadyDeployed: true,
    args: [weth, zkSyncMailbox, zkSyncErc20Bridge],
  });
};

module.exports = func;
func.tags = ["ZkSyncAdapter", "mainnet"];
