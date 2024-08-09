import { L1_ADDRESS_MAP } from "./consts";
import { DeployFunction } from "hardhat-deploy/types";
import { HardhatRuntimeEnvironment } from "hardhat/types";

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployments: { deploy }, getNamedAccounts, getChainId } = hre;
  const { deployer } = await getNamedAccounts();
  const chainId = parseInt(await getChainId());

  await deploy("Scroll_Adapter", {
    from: deployer,
    log: true,
    skipIfAlreadyDeployed: false,
    args: [
      L1_ADDRESS_MAP[chainId].scrollERC20GatewayRouter,
      L1_ADDRESS_MAP[chainId].scrollMessengerRelay,
      L1_ADDRESS_MAP[chainId].scrollGasPriceOracle,
      2_000_000, // The gas limit for arbitrary message relay L2 transactions : 2M wei
      250_000, // The gas limit for token relay L2 transactions : 250k wei
    ],
  });
};

module.exports = func;
func.tags = ["ScrollAdapter", "mainnet"];
