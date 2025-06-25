import { HardhatRuntimeEnvironment } from "hardhat/types";
import { DeployFunction } from "hardhat-deploy/types";
import { CHAIN_IDs } from "../utils";
import { L1_ADDRESS_MAP, OP_STACK_ADDRESS_MAP, USDC, WETH } from "./consts";

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const spokeChainId = Number(process.env.SPOKE_CHAIN_ID ?? CHAIN_IDs.WORLD_CHAIN);
  const { deployer } = await hre.getNamedAccounts();
  const chainId = parseInt(await hre.getChainId());
  const opStack = OP_STACK_ADDRESS_MAP[chainId][spokeChainId];

  const args = [
    WETH[chainId],
    opStack.L1CrossDomainMessenger,
    opStack.L1StandardBridge,
    USDC[chainId],
    L1_ADDRESS_MAP[chainId].cctpV2TokenMessenger,
  ];

  const instance = await hre.deployments.deploy("WorldChain_Adapter", {
    from: deployer,
    log: true,
    skipIfAlreadyDeployed: false,
    args,
  });
  await hre.run("verify:verify", { address: instance.address, constructorArguments: args });
};

module.exports = func;
func.tags = ["WorldChainAdapter", "mainnet"];
