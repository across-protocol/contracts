import { ethers } from "ethers";
import { CIRCLE_DOMAIN_IDs, L1_ADDRESS_MAP } from "./consts";
import { DeployFunction } from "hardhat-deploy/types";
import { HardhatRuntimeEnvironment } from "hardhat/types";

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployments, getNamedAccounts, getChainId, network } = hre;
  const { deploy } = deployments;

  const { deployer } = await getNamedAccounts();

  const chainId = parseInt(await getChainId());

  await deploy("Base_Adapter", {
    from: deployer,
    log: true,
    skipIfAlreadyDeployed: true,
    args: [
      L1_ADDRESS_MAP[chainId].weth,
      L1_ADDRESS_MAP[chainId].baseCrossDomainMessenger,
      L1_ADDRESS_MAP[chainId].baseStandardBridge,
      L1_ADDRESS_MAP[chainId].l1UsdcAddress,
      L1_ADDRESS_MAP[chainId].cctpTokenMessenger,
      CIRCLE_DOMAIN_IDs[8453],
    ],
  });
};

module.exports = func;
func.dependencies = ["HubPool"];
func.tags = ["BaseAdapter", "mainnet"];
