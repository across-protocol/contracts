import { ZERO_ADDRESS } from "@uma/common";
import { L1_ADDRESS_MAP } from "./consts";
import { DeployFunction } from "hardhat-deploy/types";
import { HardhatRuntimeEnvironment } from "hardhat/types";

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployments, getNamedAccounts, getChainId } = hre;
  const { deploy } = deployments;

  const { deployer } = await getNamedAccounts();

  const chainId = parseInt(await getChainId());

  await deploy("Blast_Adapter", {
    from: deployer,
    log: true,
    skipIfAlreadyDeployed: true,
    args: [
      L1_ADDRESS_MAP[chainId].weth,
      L1_ADDRESS_MAP[chainId].blastCrossDomainMessenger,
      L1_ADDRESS_MAP[chainId].blastStandardBridge,
      L1_ADDRESS_MAP[chainId].usdc,
      L1_ADDRESS_MAP[chainId].l1BlastBridge,
      L1_ADDRESS_MAP[chainId].dai,
      "200000", // 200k
    ],
  });
};

module.exports = func;
func.dependencies = ["HubPool"];
func.tags = ["BlastAdapter", "mainnet"];
