import hre from "hardhat";
import { HardhatRuntimeEnvironment } from "hardhat/types";
import { Deployment } from "hardhat-deploy/types";
import { getContractFactory } from "./utils";

export async function getSpokePoolDeploymentInfo(
  hre: HardhatRuntimeEnvironment
): Promise<{ hubPool: Deployment; hubChainId: number; spokeChainId: number }> {
  const { companionNetworks, getChainId } = hre;
  const spokeChainId = Number(await getChainId());
  const hubChain = companionNetworks.l1;
  const hubPool = await hubChain.deployments.get("HubPool");
  const hubChainId = Number(await hubChain.getChainId());
  console.log(`Using chain ${hubChainId} HubPool @ ${hubPool.address}`);

  return { hubPool, hubChainId, spokeChainId };
}

export async function deployNewProxy(name: string, args: (number | string)[]): Promise<void> {
  const { run, upgrades } = hre;

  const proxy = await upgrades.deployProxy(await getContractFactory(name, {}), args, {
    kind: "uups",
  });
  const instance = await proxy.deployed();
  console.log(`New ${name} proxy deployed @ ${instance.address}`);
  const implementationAddress = await upgrades.erc1967.getImplementationAddress(instance.address);
  console.log(`${name} implementation deployed @ ${implementationAddress}`);

  // hardhat-upgrades overrides the `verify` task that ships with `hardhat` so that if the address passed
  // is a proxy, hardhat will first verify the implementation and then the proxy and also link the proxy
  // to the implementation's ABI on etherscan.
  // https://docs.openzeppelin.com/upgrades-plugins/1.x/api-hardhat-upgrades#verify
  await run("verify:verify", {
    address: instance.address,
  });
}

export { hre };
