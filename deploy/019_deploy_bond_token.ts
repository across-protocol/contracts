import { DeployFunction } from "hardhat-deploy/types";
import { HardhatRuntimeEnvironment } from "hardhat/types";

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const contractName = "BondToken";
  const { deployments } = hre;
  const { deployer } = await hre.getNamedAccounts();
  const chainId = await hre.getChainId();
  const hubPool = await deployments.get("HubPool");
  console.log(`Using chain ${chainId} HubPool @ ${hubPool.address}.`);

  const constructorArguments = [hubPool.address];
  const deployment = await deployments.deploy(contractName, {
    from: deployer,
    log: true,
    skipIfAlreadyDeployed: true,
    args: [hubPool.address],
  });

  await hre.run("verify:verify", { address: deployment.address, constructorArguments });
};
module.exports = func;
func.dependencies = ["HubPool"];
func.tags = ["BondToken", "mainnet"];
