import { DeployFunction } from "hardhat-deploy/types";
import { HardhatRuntimeEnvironment } from "hardhat/types";
import { CHAIN_IDs } from "../utils";
import { L1_ADDRESS_MAP, OP_STACK_ADDRESS_MAP, USDC, WETH } from "./consts";
import { getHyperlaneDomainId, toWei } from "../utils/utils";

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployer } = await hre.getNamedAccounts();
  const chainId = parseInt(await hre.getChainId());

  const spokeChainId = chainId == CHAIN_IDs.MAINNET ? CHAIN_IDs.OPTIMISM : CHAIN_IDs.OPTIMISM_SEPOLIA;

  const opStack = OP_STACK_ADDRESS_MAP[chainId][spokeChainId];

  const hyperlaneDstDomain = getHyperlaneDomainId(spokeChainId);
  const hyperlaneXERC20FeeCap = toWei("1"); // 1 eth transfer fee cap

  const args = [
    WETH[chainId],
    opStack.L1CrossDomainMessenger,
    opStack.L1StandardBridge,
    USDC[chainId],
    L1_ADDRESS_MAP[chainId].cctpTokenMessenger,
    L1_ADDRESS_MAP[chainId].adapterStore,
    hyperlaneDstDomain,
    hyperlaneXERC20FeeCap,
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
