import "hardhat-deploy";
import hre from "hardhat";
import { getContractFactory } from "../utils";

const func = async function () {
  const { upgrades, companionNetworks, run, getNamedAccounts } = hre;

  // Grab L1 addresses:
  const { deployments: l1Deployments } = companionNetworks.l1;
  const hubPool = await l1Deployments.get("HubPool");
  console.log(`Using l1 hub pool @ ${hubPool.address}`);

  // Initialize deposit counter to very high number of deposits to avoid duplicate deposit ID's
  // with deprecated spoke pool.
  // Set hub pool as cross domain admin since it delegatecalls the Adapter logic.
  const { deployer } = await getNamedAccounts();
  const constructorArgs = [1_000_000, hubPool.address, hubPool.address];
  const spokePool = await upgrades.deployProxy(await getContractFactory("Boba_SpokePool", deployer), constructorArgs, {
    kind: "uups",
  });
  const instance = await spokePool.deployed();
  console.log(`SpokePool deployed @ ${instance.address}`);
  const implementationAddress = await upgrades.erc1967.getImplementationAddress(instance.address);
  console.log(`Implementation deployed @ ${implementationAddress}`);

  // hardhat-upgrades overrides the `verify` task that ships with `hardhat` so that if the address passed
  // is a proxy, hardhat will first verify the implementation and then the proxy and also link the proxy
  // to the implementation's ABI on etherscan.
  // https://docs.openzeppelin.com/upgrades-plugins/1.x/api-hardhat-upgrades#verify
  await run("verify:verify", {
    address: instance.address,
  });
};
module.exports = func;
func.tags = ["BobaSpokePool", "boba"];
