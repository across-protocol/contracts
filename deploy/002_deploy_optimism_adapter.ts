// Cross Domain Messengers grabbed from
// https://github.com/ethereum-optimism/optimism/tree/develop/packages/contracts/deployments

import { L1_ADDRESS_MAP } from "./consts";

// This import is needed to override the definition of the HardhatRuntimeEnvironment type.
import "hardhat-deploy";
import { HardhatRuntimeEnvironment } from "hardhat/types/runtime";

const func = async function (hre: HardhatRuntimeEnvironment) {
  const { deployments, getNamedAccounts, getChainId } = hre;
  const { deploy } = deployments;

  const { deployer } = await getNamedAccounts();

  const chainId = parseInt(await getChainId());

  await deploy("Optimism_Adapter", {
    from: deployer,
    log: true,
    skipIfAlreadyDeployed: true,
    args: [
      L1_ADDRESS_MAP[chainId].weth,
      L1_ADDRESS_MAP[chainId].optimismCrossDomainMessenger,
      L1_ADDRESS_MAP[chainId].optimismStandardBridge,
    ],
  });
};

module.exports = func;
func.dependencies = ["HubPool"];
func.tags = ["OptimismAdapter", "mainnet"];
