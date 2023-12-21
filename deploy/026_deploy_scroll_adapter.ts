import { L1_ADDRESS_MAP } from "./consts";
import { DeployFunction } from "hardhat-deploy/types";
import { HardhatRuntimeEnvironment } from "hardhat/types";

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployments, getNamedAccounts, getChainId } = hre;
  const { deploy } = deployments;

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
    ],
  });
};

module.exports = func;
func.tags = ["ScrollAdapter", "mainnet"];
