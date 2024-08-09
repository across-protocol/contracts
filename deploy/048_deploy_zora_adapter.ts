import { ZERO_ADDRESS } from "@uma/common";
import { DeployFunction } from "hardhat-deploy/types";
import { HardhatRuntimeEnvironment } from "hardhat/types";
import { L1_ADDRESS_MAP, WETH } from "./consts";

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployments, getNamedAccounts, getChainId, network } = hre;
  const { deploy } = deployments;

  const { deployer } = await getNamedAccounts();

  const chainId = parseInt(await getChainId());

  await deploy("Zora_Adapter", {
    from: deployer,
    log: true,
    skipIfAlreadyDeployed: true,
    args: [
      WETH[chainId],
      L1_ADDRESS_MAP[chainId].zoraCrossDomainMessenger,
      L1_ADDRESS_MAP[chainId].zoraStandardBridge,
      ZERO_ADDRESS,
    ],
  });
};

module.exports = func;
func.tags = ["ZoraAdapter", "mainnet"];
