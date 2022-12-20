import { L2_ADDRESS_MAP } from "./consts";

import "hardhat-deploy";
import { HardhatRuntimeEnvironment } from "hardhat/types/runtime";

const func = async function (hre: HardhatRuntimeEnvironment) {
  const { deployments, getNamedAccounts, getChainId } = hre;
  const { deploy } = deployments;

  const { deployer } = await getNamedAccounts();

  const chainId = parseInt(await getChainId());
  const spokePool = await deployments.get("Optimism_SpokePool");
  console.log(`Using spoke pool @ ${spokePool.address}`);

  await deploy("OVM_SpokeAdapter", {
    from: deployer,
    log: true,
    skipIfAlreadyDeployed: true,
    args: [spokePool.address, L2_ADDRESS_MAP[chainId].l2Eth],
  });
};

module.exports = func;
func.dependencies = ["OptimismSpokePool"];
func.tags = ["OptimismSpokeAdapter", "optimism"];
