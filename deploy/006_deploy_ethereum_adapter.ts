// This import is needed to override the definition of the HardhatRuntimeEnvironment type.
import "hardhat-deploy";
import { HardhatRuntimeEnvironment } from "hardhat/types/runtime";

const func = async function (hre: HardhatRuntimeEnvironment) {
  const { deployments, getNamedAccounts } = hre;
  const { deploy } = deployments;

  const { deployer } = await getNamedAccounts();

  await deploy("Ethereum_Adapter", {
    from: deployer,
    log: true,
    skipIfAlreadyDeployed: true,
    args: [],
  });
};

module.exports = func;
func.dependencies = ["HubPool"];
func.tags = ["EthereumAdapter", "mainnet"];
