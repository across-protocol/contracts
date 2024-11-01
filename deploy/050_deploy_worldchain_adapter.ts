import { HardhatRuntimeEnvironment } from "hardhat/types";
import { DeployFunction } from "hardhat-deploy/types";
import { CHAIN_IDs } from "../utils";
import { OP_STACK_ADDRESS_MAP, WETH, ZERO_ADDRESS } from "./consts";

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployer } = await hre.getNamedAccounts();
  const chainId = parseInt(await hre.getChainId());

  await hre.deployments.deploy("OP_Adapter", {
    from: deployer,
    log: true,
    skipIfAlreadyDeployed: true,
    args: [
      WETH[chainId],
      USDC[chainId],
      OP_STACK_ADDRESS_MAP[chainId][CHAIN_IDs.WORLD_CHAIN].L1CrossDomainMessenger,
      OP_STACK_ADDRESS_MAP[chainId][CHAIN_IDs.WORLD_CHAIN].L1StandardBridge,
      OP_STACK_ADDRESS_MAP[chainId][CHAIN_IDs.WORLD_CHAIN].L1OpUSDCBridge,
      ZERO_ADDRESS,
    ],
  });
};

module.exports = func;
func.tags = ["WorldChainAdapter", "mainnet"];
