import "hardhat-deploy";
import { HardhatRuntimeEnvironment } from "hardhat/types/runtime";

import { L1_ADDRESS_MAP } from "./consts";

const func = async function (hre: HardhatRuntimeEnvironment) {
  const { deployments, getNamedAccounts, getChainId } = hre;
  const { deploy } = deployments;

  const { deployer } = await getNamedAccounts();

  const chainId = parseInt(await getChainId());

  const hubPool = await deployments.get("HubPool");
  console.log(`Using l1 hub pool @ ${hubPool.address}`);

  await deploy("Ethereum_SpokePool", {
    from: deployer,
    log: true,
    skipIfAlreadyDeployed: true,
    args: [hubPool.address, L1_ADDRESS_MAP[chainId].weth, "0x0000000000000000000000000000000000000000"],
  });
};
module.exports = func;
func.tags = ["EthereumSpokePool", "mainnet"];
