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

  // Set the Hyperlane xERC20 destination domain based on the chain https://github.com/hyperlane-xyz/hyperlane-registry/tree/main/chains
  const hypXERC20DstDomain = chainId == CHAIN_IDs.MAINNET ? 10 : 11155420;
  const hypXERC20FeeCap = toWei("1"); // 1 eth transfer fee cap

  const args = [
    WETH[chainId],
    opStack.L1CrossDomainMessenger,
    opStack.L1StandardBridge,
    USDC[chainId],
    L1_ADDRESS_MAP[chainId].cctpTokenMessenger,
    L1_ADDRESS_MAP[chainId].adapterStore,
    hypXERC20DstDomain,
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
