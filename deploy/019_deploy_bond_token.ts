import "hardhat-deploy";
import { HardhatRuntimeEnvironment } from "hardhat/types/runtime";

const func = async function (hre: HardhatRuntimeEnvironment) {
  const { deployments, getNamedAccounts } = hre;
  const { deployer } = await getNamedAccounts();

  const hubPool = await deployments.get("HubPool");
  console.log(`Using l1 hub pool @ ${hubPool.address}.`);

  await deployments.deploy("BondToken", {
    from: deployer,
    log: true,
    skipIfAlreadyDeployed: true,
    args: [hubPool.address],
  });
};
module.exports = func;
func.dependencies = ["HubPool"];
func.tags = ["BondToken", "mainnet"];
