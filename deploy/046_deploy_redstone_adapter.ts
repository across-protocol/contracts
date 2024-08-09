import { HardhatRuntimeEnvironment } from "hardhat/types";
import { DeployFunction } from "hardhat-deploy/types";
import { L1_ADDRESS_MAP, WETH, ZERO_ADDRESS } from "./consts";

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const {
    deployments: { deploy },
    getNamedAccounts,
    getChainId,
  } = hre;
  const { deployer } = await getNamedAccounts();
  const chainId = parseInt(await getChainId());

  await deploy("Redstone_Adapter", {
    from: deployer,
    log: true,
    skipIfAlreadyDeployed: true,
    args: [
      WETH[chainId],
      L1_ADDRESS_MAP[chainId].redstoneCrossDomainMessenger,
      L1_ADDRESS_MAP[chainId].redstoneStandardBridge,
      ZERO_ADDRESS,
    ],
  });
};

module.exports = func;
func.tags = ["RedstoneAdapter", "mainnet"];
