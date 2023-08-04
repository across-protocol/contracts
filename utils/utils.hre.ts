import { getContractFactory } from "./utils";
import hre from "hardhat";

export async function deployNewProxy(name: string, args: (number | string)[]): Promise<void> {
  const { run, upgrades } = hre;

  const proxy = await upgrades.deployProxy(await getContractFactory(name, {}), args, {
    kind: "uups",
    unsafeAllow: ["delegatecall"],
  });
  const instance = await proxy.deployed();
  console.log(`New ${name} proxy deployed @ ${instance.address}`);
  const implementationAddress = await upgrades.erc1967.getImplementationAddress(instance.address);
  console.log(`${name} implementation deployed @ ${implementationAddress}`);

  // hardhat-upgrades overrides the `verify` task that ships with `hardhat` so that if the address passed
  // is a proxy, hardhat will first verify the implementation and then the proxy and also link the proxy
  // to the implementation's ABI on etherscan.
  // https://docs.openzeppelin.com/upgrades-plugins/1.x/api-hardhat-upgrades#verify
  // await run("verify:verify", {
  //   address: instance.address,
  //   contract: "contracts/Base_SpokePool.sol:Base_SpokePool",
  // });
}

export { hre };
