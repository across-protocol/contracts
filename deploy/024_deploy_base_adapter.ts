import { L1_ADDRESS_MAP } from "./consts";
import { DeployFunction } from "hardhat-deploy/types";
import { HardhatRuntimeEnvironment } from "hardhat/types";

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployments, getNamedAccounts, getChainId } = hre;
  const { deploy } = deployments;

  const { deployer } = await getNamedAccounts();

  const chainId = parseInt(await getChainId());

  const args = [
    L1_ADDRESS_MAP[chainId].weth,
    L1_ADDRESS_MAP[chainId].baseCrossDomainMessenger,
    L1_ADDRESS_MAP[chainId].baseStandardBridge,
    L1_ADDRESS_MAP[chainId].usdc,
    L1_ADDRESS_MAP[chainId].cctpTokenMessenger,
  ];
  const instance = await deploy("Base_Adapter", {
    from: deployer,
    log: true,
    skipIfAlreadyDeployed: true,
    args,
  });
  await run("verify:verify", { address: instance.address, constructorArguments: args });
};

module.exports = func;
func.tags = ["BaseAdapter", "mainnet"];
