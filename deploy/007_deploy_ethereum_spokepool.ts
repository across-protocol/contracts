import "hardhat-deploy";

import hre from "hardhat";
import { getContractFactory } from "../utils";

import { L1_ADDRESS_MAP } from "./consts";

export async function printProxyVerificationInstructions() {}

const func = async function () {
  const { deployments, getChainId, upgrades, run, getNamedAccounts } = hre;

  const chainId = parseInt(await getChainId());
  const { deployer } = await getNamedAccounts();

  const hubPool = await deployments.get("HubPool");
  console.log(`Using l1 hub pool @ ${hubPool.address}`);

  // Initialize deposit counter to very high number of deposits to avoid duplicate deposit ID's
  // with deprecated spoke pool.
  const constructorArgs = [1_000_000, hubPool.address, L1_ADDRESS_MAP[chainId].weth];
  const spokePool = await upgrades.deployProxy(
    await getContractFactory("Ethereum_SpokePool", deployer),
    constructorArgs,
    {
      kind: "uups",
    }
  );
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

  // Transfer ownership to hub pool.
};
module.exports = func;
func.tags = ["EthereumSpokePool", "mainnet"];
