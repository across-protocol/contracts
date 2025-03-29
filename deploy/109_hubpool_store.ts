import { DeployFunction } from "hardhat-deploy/types";
import { HardhatRuntimeEnvironment } from "hardhat/types";
import assert from "assert";

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { SPOKE_CHAIN_ID } = process.env;
  assert(SPOKE_CHAIN_ID, "SPOKE_CHAIN_ID is required");

  const { deployer, deployments } = await hre.getNamedAccounts();
  const hubPool = await deployments.get("HubPool");

  const args = [hubPool.address];
  const instance = await deployments.deploy("HubPoolStore", {
    from: deployer,
    log: true,
    skipIfAlreadyDeployed: true,
    args,
  });
  await hre.run("verify:verify", { address: instance.address, constructorArguments: args });
};

module.exports = func;
func.tags = ["HubPoolStore", "universalStorageProof"];
