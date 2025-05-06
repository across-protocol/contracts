import { HardhatRuntimeEnvironment } from "hardhat/types";
import { DeployFunction } from "hardhat-deploy/types";
import { CHAIN_IDs } from "../utils";
import { OP_STACK_ADDRESS_MAP, USDC, WETH } from "./consts";

const SPOKE_CHAIN_ID = CHAIN_IDs.BOBA;

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployer } = await hre.getNamedAccounts();
  const chainId = parseInt(await hre.getChainId());
  const opStack = OP_STACK_ADDRESS_MAP[chainId][SPOKE_CHAIN_ID];

  await hre.deployments.deploy("Mode_Adapter", {
    from: deployer,
    log: true,
    skipIfAlreadyDeployed: true,
    args: [WETH[chainId], opStack.L1CrossDomainMessenger, opStack.L1StandardBridge, USDC[chainId]],
  });
};

module.exports = func;
func.tags = ["ModeAdapter", "mainnet"];
