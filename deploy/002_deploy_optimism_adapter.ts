import { DeployFunction } from "hardhat-deploy/types";
import { HardhatRuntimeEnvironment } from "hardhat/types";
import { CHAIN_IDs } from "../utils";
import { L1_ADDRESS_MAP, OP_STACK_ADDRESS_MAP, USDC, WETH } from "./consts";
import { toWei } from "../utils/utils";

const SPOKE_CHAIN_ID = CHAIN_IDs.OPTIMISM;

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployer } = await hre.getNamedAccounts();
  const chainId = parseInt(await hre.getChainId());
  const opStack = OP_STACK_ADDRESS_MAP[chainId][SPOKE_CHAIN_ID];

  // 1 ether is our default Hyperlane xERC20 fee cap on chains with ETH as gas token
  const hypXERC20FeeCap = toWei("1");
  // Pick correct destination chain id to set based on deployment network
  const dstChainId = chainId == CHAIN_IDs.MAINNET ? CHAIN_IDs.OPTIMISM : CHAIN_IDs.OPTIMISM_SEPOLIA;

  const args = [
    WETH[chainId],
    opStack.L1CrossDomainMessenger,
    opStack.L1StandardBridge,
    USDC[chainId],
    L1_ADDRESS_MAP[chainId].cctpTokenMessenger,
    dstChainId,
    L1_ADDRESS_MAP[chainId].adapterStore,
    hypXERC20FeeCap,
  ];
  const instance = await hre.deployments.deploy("Optimism_Adapter", {
    from: deployer,
    log: true,
    skipIfAlreadyDeployed: false,
    args: args,
  });
  await hre.run("verify:verify", { address: instance.address, constructorArguments: args });
};

module.exports = func;
func.tags = ["OptimismAdapter", "mainnet"];
