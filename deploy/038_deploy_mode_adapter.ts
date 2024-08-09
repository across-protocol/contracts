import { HardhatRuntimeEnvironment } from "hardhat/types";
import { DeployFunction } from "hardhat-deploy/types";
import { L1_ADDRESS_MAP, USDC, WETH } from "./consts";

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const {
    deployments: { deploy },
    getNamedAccounts,
    getChainId,
  } = hre;
  const { deployer } = await getNamedAccounts();
  const chainId = parseInt(await getChainId());

  await deploy("Mode_Adapter", {
    from: deployer,
    log: true,
    skipIfAlreadyDeployed: true,
    args: [
      WETH[chainId],
      L1_ADDRESS_MAP[chainId].modeCrossDomainMessenger,
      L1_ADDRESS_MAP[chainId].modeStandardBridge,
      USDC[chainId],
    ],
  });
};

module.exports = func;
func.tags = ["ModeAdapter", "mainnet"];
