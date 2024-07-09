import hre from "hardhat";
import { HardhatRuntimeEnvironment } from "hardhat/types";
import { Deployment, DeploymentSubmission } from "hardhat-deploy/types";
import { getContractFactory } from "./utils";
import { CHAIN_IDs } from "@across-protocol/constants";

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

type FnArgs = number | string;
export async function deployNewProxy(
  name: string,
  constructorArgs: FnArgs[],
  initArgs: FnArgs[],
  implementationOnly = false
): Promise<void> {
  const { deployments, run, upgrades, getChainId } = hre;
  let chainId = Number(await getChainId());

  let instance: string;
  let unsafeAllowArgs = ["delegatecall"]; // Remove after upgrading openzeppelin-contracts-upgradeable post v4.9.3.
  if (chainId === CHAIN_IDs.BLAST || chainId === CHAIN_IDs.BLAST_SEPOLIA) {
    unsafeAllowArgs.push("state-variable-immutable");
  }
  if (implementationOnly) {
    instance = (await upgrades.deployImplementation(await getContractFactory(name, {}), {
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
    instance = (await proxy.deployed()).address;
    console.log(`New ${name} proxy deployed @ ${instance}`);
    const implementationAddress = await upgrades.erc1967.getImplementationAddress(instance);
    console.log(`${name} implementation deployed @ ${implementationAddress}`);
  }

  // Save the deployment manually because OZ's hardhat-upgrades packages bypasses hardhat-deploy.
  // See also: https://stackoverflow.com/questions/74870472
  const artifact = await deployments.getExtendedArtifact(name);
  const deployment: DeploymentSubmission = {
    address: instance,
    ...artifact,
  };
  await deployments.save(name, deployment);

  // hardhat-upgrades overrides the `verify` task that ships with `hardhat` so that if the address passed
  // is a proxy, hardhat will first verify the implementation and then the proxy and also link the proxy
  // to the implementation's ABI on etherscan.
  // https://docs.openzeppelin.com/upgrades-plugins/1.x/api-hardhat-upgrades#verify
  await run("verify:verify", { address: instance, constructorArguments: constructorArgs });
}

export { hre };
