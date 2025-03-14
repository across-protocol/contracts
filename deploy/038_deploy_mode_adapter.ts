import { HardhatRuntimeEnvironment } from "hardhat/types";
import { DeployFunction } from "hardhat-deploy/types";
import { CHAIN_IDs } from "../utils";
import { L1_ADDRESS_MAP, OP_STACK_ADDRESS_MAP, USDC, WETH } from "./consts";
import { toWei } from "../utils/utils";

const SPOKE_CHAIN_ID = CHAIN_IDs.BOBA;

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployer } = await hre.getNamedAccounts();
  const chainId = parseInt(await hre.getChainId());
  const opStack = OP_STACK_ADDRESS_MAP[chainId][SPOKE_CHAIN_ID];

  // Pick correct destination chain id to set based on deployment network
  const dstChainId = chainId == CHAIN_IDs.MAINNET ? CHAIN_IDs.MODE : CHAIN_IDs.MODE_SEPOLIA;

  // 1 ether is our default Hyperlane xERC20 fee cap on chains with ETH as gas token
  const hypXERC20FeeCap = toWei("1");

  await hre.deployments.deploy("Mode_Adapter", {
    from: deployer,
    log: true,
    skipIfAlreadyDeployed: true,
    args: [
      WETH[chainId],
      opStack.L1CrossDomainMessenger,
      opStack.L1StandardBridge,
      USDC[chainId],
      dstChainId,
      L1_ADDRESS_MAP[chainId].adapterStore,
      hypXERC20FeeCap,
    ],
  });
};

module.exports = func;
func.tags = ["ModeAdapter", "mainnet"];
