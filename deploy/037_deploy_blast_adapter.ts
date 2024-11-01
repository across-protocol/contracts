import { DeployFunction } from "hardhat-deploy/types";
import { HardhatRuntimeEnvironment } from "hardhat/types";
import { CHAIN_IDs, TOKEN_SYMBOLS_MAP } from "../utils";
import { OP_STACK_ADDRESS_MAP, USDC, WETH } from "./consts";

const USDB = TOKEN_SYMBOLS_MAP.USDB.addresses;

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployer } = await hre.getNamedAccounts();
  const chainId = parseInt(await hre.getChainId());

  await hre.deployments.deploy("Blast_Adapter", {
    from: deployer,
    log: true,
    skipIfAlreadyDeployed: true,
    args: [
      WETH[chainId],
      OP_STACK_ADDRESS_MAP[chainId][CHAIN_IDs.BLAST].L1CrossDomainMessenger,
      OP_STACK_ADDRESS_MAP[chainId][CHAIN_IDs.BLAST].L1StandardBridge,
      USDC[chainId],
      OP_STACK_ADDRESS_MAP[chainId][CHAIN_IDs.BLAST].L1BlastBridge,
      USDB[chainId],
      "200_000",
    ],
  });
};

module.exports = func;
func.dependencies = ["HubPool"];
func.tags = ["BlastAdapter", "mainnet"];
