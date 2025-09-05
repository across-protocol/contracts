import assert from "assert";
import { DeployFunction } from "hardhat-deploy/types";
import { HardhatRuntimeEnvironment } from "hardhat/types";

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployer } = await hre.getNamedAccounts();
  const { deployments } = hre;

  // ! Notice. Deployer should specify their own adapter that will be used as underlying adapter to `relayTokens` to target chain
  // In this current deployment we're using prod Arbitrum_Adapter (HubPool.crossChainContracts(42161).adapter) to be able to send
  // tokens back to Arbitrum
  const underlyingAdapter = "0x5eC9844936875E27eBF22172f4d92E107D35B57C";
  // Make sure we're indeed using the latest version of the adapter. If the 2 conflict, need to check manually
  assert((await deployments.get("Arbitrum_Adapter")).address === underlyingAdapter);

  const args = [underlyingAdapter];
  const instance = await hre.deployments.deploy("AdminRelayTokensAdapter", {
    from: deployer,
    log: true,
    skipIfAlreadyDeployed: false,
    args,
  });
  await hre.run("verify:verify", { address: instance.address, constructorArguments: args });
};

module.exports = func;
func.tags = ["AdminRelayTokensAdapter", "mainnet"];
