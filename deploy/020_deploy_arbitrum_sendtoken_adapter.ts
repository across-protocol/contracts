import { L1_ADDRESS_MAP } from "./consts";
import { DeployFunction } from "hardhat-deploy/types";
import { HardhatRuntimeEnvironment } from "hardhat/types";

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const {
    deployments: { deploy },
    getNamedAccounts,
    getChainId,
  } = hre;
  const { deployer } = await getNamedAccounts();
  const chainId = parseInt(await getChainId());

  await deploy("Arbitrum_SendTokensAdapter", {
    from: deployer,
    log: true,
    skipIfAlreadyDeployed: true,
    args: [L1_ADDRESS_MAP[chainId].l1ERC20GatewayRouter],
  });
};

module.exports = func;
func.tags = ["ArbitrumSendTokensAdapter", "mainnet"];
