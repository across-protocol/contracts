import { DeployFunction } from "hardhat-deploy/types";
import { getContractFactory } from "../utils";
import * as deployments from "../deployments/deployments.json";
import { HardhatRuntimeEnvironment } from "hardhat/types";
import { FILL_DEADLINE_BUFFER, QUOTE_TIME_BUFFER, WETH } from "./consts";

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployer } = await hre.getNamedAccounts();
  const chainId = parseInt(await hre.getChainId());
  const spokePool = await deployments[chainId].SpokePool;
  console.log(`Using spoke pool @ ${spokePool.address}`);

  // Deploy new implementation and validate that it can be used in upgrade, without actually upgrading it.
  const newImplementation = await hre.upgrades.prepareUpgrade(
    spokePool.address,
    await getContractFactory("Ethereum_SpokePool", deployer),
    { constructorArgs: [WETH[chainId], QUOTE_TIME_BUFFER, FILL_DEADLINE_BUFFER] }
  );
  console.log(`Can upgrade to new implementation @ ${newImplementation}`);

  // hardhat-upgrades overrides the `verify` task that ships with `hardhat` so that if the address passed
  // is a proxy, hardhat will first verify the implementation and then the proxy and also link the proxy
  // to the implementation's ABI on etherscan.
  // https://docs.openzeppelin.com/upgrades-plugins/1.x/api-hardhat-upgrades#verify
  await hre.run("verify:verify", {
    address: newImplementation,
  });
};
module.exports = func;
func.tags = ["UpgradeSpokePool"];
