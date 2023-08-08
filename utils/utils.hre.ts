import hre from "hardhat";
import { DeploymentSubmission } from "hardhat-deploy/types";
import { getContractFactory } from "./utils";

export async function deployNewProxy(name: string, args: (number | string)[]): Promise<void> {
  const { deployments, run, upgrades } = hre;

  const proxy = await upgrades.deployProxy(await getContractFactory(name, {}), args, {
    kind: "uups",
    unsafeAllow: ["delegatecall"], // Remove after upgrading openzeppelin-contracts-upgradeable post v4.9.3.
  });
  const instance = await proxy.deployed();
  console.log(`New ${name} proxy deployed @ ${instance.address}`);
  const implementationAddress = await upgrades.erc1967.getImplementationAddress(instance.address);
  console.log(`${name} implementation deployed @ ${implementationAddress}`);

  // Save the deployment manually because OZ's hardhat-upgrades packages bypasses hardhat-deploy.
  // See also: https://stackoverflow.com/questions/74870472
  const artifact = await deployments.getExtendedArtifact(name);
  const deployment: DeploymentSubmission = {
    address: instance.address,
    ...artifact,
  };
  await deployments.save(name, deployment);

  // hardhat-upgrades overrides the `verify` task that ships with `hardhat` so that if the address passed
  // is a proxy, hardhat will first verify the implementation and then the proxy and also link the proxy
  // to the implementation's ABI on etherscan.
  // https://docs.openzeppelin.com/upgrades-plugins/1.x/api-hardhat-upgrades#verify
  await run("verify:verify", { address: instance.address });
}

export { hre };
