import { L1_ADDRESS_MAP, USDC, WETH } from "./consts";
import { DeployFunction } from "hardhat-deploy/types";
import { HardhatRuntimeEnvironment } from "hardhat/types";

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployments: { deploy }, getNamedAccounts, getChainId } = hre;
  const { deployer } = await getNamedAccounts();
  const chainId = parseInt(await getChainId());

  const args = [
    WETH[chainId],
    L1_ADDRESS_MAP[chainId].optimismCrossDomainMessenger,
    L1_ADDRESS_MAP[chainId].optimismStandardBridge,
    USDC[chainId],
    L1_ADDRESS_MAP[chainId].cctpTokenMessenger,
  ];
  const instance = await deploy("Optimism_Adapter", {
    from: deployer,
    log: true,
    skipIfAlreadyDeployed: false,
    args: args,
  });
  await run("verify:verify", { address: instance.address, constructorArguments: args });
};

module.exports = func;
func.tags = ["OptimismAdapter", "mainnet"];
