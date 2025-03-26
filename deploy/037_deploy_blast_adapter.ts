import { DeployFunction } from "hardhat-deploy/types";
import { HardhatRuntimeEnvironment } from "hardhat/types";
import { CHAIN_IDs, TOKEN_SYMBOLS_MAP } from "../utils";
import { L1_ADDRESS_MAP, OP_STACK_ADDRESS_MAP, USDC, WETH } from "./consts";
import { getHyperlaneDomainId, toWei } from "../utils/utils";

const USDB = TOKEN_SYMBOLS_MAP.USDB.addresses;

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployer } = await hre.getNamedAccounts();
  const chainId = parseInt(await hre.getChainId());
  const spokeChainId = chainId == CHAIN_IDs.MAINNET ? CHAIN_IDs.BLAST : CHAIN_IDs.BLAST_SEPOLIA;
  const opStack = OP_STACK_ADDRESS_MAP[chainId][spokeChainId];

  const hyperlaneDstDomain = getHyperlaneDomainId(spokeChainId);
  const hyperlaneXERC20FeeCap = toWei("1"); // 1 eth transfer fee cap

  await hre.deployments.deploy("Blast_Adapter", {
    from: deployer,
    log: true,
    skipIfAlreadyDeployed: true,
    args: [
      WETH[chainId],
      opStack.L1CrossDomainMessenger,
      opStack.L1StandardBridge,
      USDC[chainId],
      opStack.L1BlastBridge,
      USDB[chainId],
      "200_000",
      L1_ADDRESS_MAP[chainId].adapterStore,
      hyperlaneDstDomain,
      hyperlaneXERC20FeeCap,
    ],
  });
};

module.exports = func;
func.dependencies = ["HubPool"];
func.tags = ["BlastAdapter", "mainnet"];
