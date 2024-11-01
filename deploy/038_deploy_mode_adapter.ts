import { HardhatRuntimeEnvironment } from "hardhat/types";
import { DeployFunction } from "hardhat-deploy/types";
import { CHAIN_IDs } from "../utils";
import { OP_STACK_ADDRESS_MAP, USDC, WETH } from "./consts";

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployer } = await hre.getNamedAccounts();
  const chainId = parseInt(await hre.getChainId());

  await hre.deployments.deploy("Mode_Adapter", {
    from: deployer,
    log: true,
    skipIfAlreadyDeployed: true,
    args: [
      WETH[chainId],
      OP_STACK_ADDRESS_MAP[chainId][CHAIN_IDs.MODE].L1CrossDomainMessenger,
      OP_STACK_ADDRESS_MAP[chainId][CHAIN_IDs.MODE].LStandardBridge,
      USDC[chainId],
    ],
  });
};

module.exports = func;
func.tags = ["ModeAdapter", "mainnet"];
