import hre from "hardhat";
import { HardhatRuntimeEnvironment } from "hardhat/types";
import { Deployment, DeploymentSubmission } from "hardhat-deploy/types";
import { CHAIN_IDs } from "@across-protocol/constants";
import { getDeployedAddress } from "../src/DeploymentUtils";
import { BigNumber, getContractFactory, toBN } from "./utils";

type unsafeAllowTypes = (
  | "delegatecall"
  | "state-variable-immutable"
  | "constructor"
  | "selfdestruct"
  | "state-variable-assignment"
  | "external-library-linking"
  | "struct-definition"
  | "enum-definition"
  | "missing-public-upgradeto"
)[];

/**
 * @description Resolve the HubPool deployment, as well as the HubPool and SpokePool chain IDs for a new deployment.
 * @dev This function relies on having companionNetworks defined in the HardhatUserConfig.
 * @dev This should only be used when deploying a SpokePool to a satellite chain (i.e. HubChainId != SpokeChainId).
 * @returns HubPool instance, HubPool chain ID and SpokePool chain ID.
 */
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

type FnArgs = number | string | BigNumber;
export async function deployNewProxy(
  name: string,
  constructorArgs: FnArgs[],
  initArgs: FnArgs[],
  implementationOnly?: boolean
): Promise<{ proxyAddress?: string; implementationAddress: string }> {
  const { deployments, run, upgrades, getChainId } = hre;
  let chainId = Number(await getChainId());

  let instance: string;
  let unsafeAllowArgs = ["delegatecall"]; // Remove after upgrading openzeppelin-contracts-upgradeable post v4.9.3.
  if ([CHAIN_IDs.BLAST, CHAIN_IDs.BLAST_SEPOLIA].includes(chainId) || ["Universal_SpokePool"].includes(name)) {
    unsafeAllowArgs.push("state-variable-immutable");
  }

  // If a SpokePool can be found in deployments/deployments.json, then only deploy an implementation contract.
  let proxyAddress = getDeployedAddress("SpokePool", chainId, false);
  implementationOnly ??= proxyAddress !== undefined;
  let implementationAddress: string;
  if (implementationOnly) {
    console.log(`${name} deployment already detected @ ${proxyAddress}, deploying new implementation.`);
    implementationAddress = instance = (await upgrades.deployImplementation(await getContractFactory(name, {}), {
      constructorArgs,
      kind: "uups",
      unsafeAllow: unsafeAllowArgs as unsafeAllowTypes,
    })) as string;
    console.log(`New ${name} implementation deployed @ ${instance}`);
  } else {
    const proxy = await upgrades.deployProxy(await getContractFactory(name, {}), initArgs, {
      kind: "uups",
      unsafeAllow: unsafeAllowArgs as unsafeAllowTypes,
      constructorArgs,
      initializer: "initialize",
    });
    proxyAddress = instance = (await proxy.deployed()).address;
    console.log(`New ${name} proxy deployed @ ${instance}`);
    implementationAddress = await upgrades.erc1967.getImplementationAddress(instance);
    console.log(`${name} implementation deployed @ ${implementationAddress}`);
  }

  // Save the deployment manually because OZ's hardhat-upgrades packages bypasses hardhat-deploy.
  // See also: https://stackoverflow.com/questions/74870472
  const artifact = await deployments.getExtendedArtifact(name);
  const deployment: DeploymentSubmission = {
    address: instance,
    args: constructorArgs,
    ...artifact,
  };
  await deployments.save(name, deployment);

  // hardhat-upgrades overrides the `verify` task that ships with `hardhat` so that if the address passed
  // is a proxy, hardhat will first verify the implementation and then the proxy and also link the proxy
  // to the implementation's ABI on etherscan.
  // https://docs.openzeppelin.com/upgrades-plugins/1.x/api-hardhat-upgrades#verify
  const contract = `contracts/${name}.sol:${name}`;
  await verifyContract(instance, constructorArgs, contract);

  return { proxyAddress, implementationAddress };
}

export async function verifyContract(address: string, constructorArguments: any[], contract?: string) {
  const { run, getChainId } = hre;
  const chainId = Number(await getChainId());
  if (hre.config.blockscout.enabled && hre.config.blockscout.customChains.some((chain) => chain.chainId === chainId)) {
    await run("verify:blockscout", { address, constructorArguments, contract });
  } else {
    await run("verify:verify", { address, constructorArguments, contract });
  }
}

export { hre };
