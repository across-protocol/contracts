import { DeployFunction } from "hardhat-deploy/types";
import { HardhatRuntimeEnvironment } from "hardhat/types";
import { CHAIN_IDs, TOKEN_SYMBOLS_MAP } from "../utils";
import { OP_STACK_ADDRESS_MAP, USDC, WETH } from "./consts";

const USDB = TOKEN_SYMBOLS_MAP.USDB.addresses;
const SPOKE_CHAIN_ID = CHAIN_IDs.BLAST;

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployer } = await hre.getNamedAccounts();
  const chainId = parseInt(await hre.getChainId());
  const opStack = OP_STACK_ADDRESS_MAP[chainId][SPOKE_CHAIN_ID];

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
    ],
  });
};

module.exports = func;
func.dependencies = ["HubPool"];
func.tags = ["BlastAdapter", "mainnet"];
