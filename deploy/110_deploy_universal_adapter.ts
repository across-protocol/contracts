import { DeployFunction } from "hardhat-deploy/types";
import { HardhatRuntimeEnvironment } from "hardhat/types";
import { CIRCLE_DOMAIN_IDs, L1_ADDRESS_MAP, USDC } from "./consts";
import assert from "assert";

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { SPOKE_CHAIN_ID } = process.env;
  assert(SPOKE_CHAIN_ID, "SPOKE_CHAIN_ID is required");

  const { deployer, deployments } = await hre.getNamedAccounts();
  const chainId = parseInt(await hre.getChainId());

  // Warning: re-using the same HubPoolStore for different L2's is only safe if the L2 spoke pools have
  // unique addresses, since the relayed message `targets` are part of the unique data hash.
  const hubPool = await deployments.get("HubPool");
  const hubPoolStore = await deployments.deploy("HubPoolStore", {
    from: deployer,
    log: true,
    skipIfAlreadyDeployed: true,
    args: [hubPool.address],
  });

  const args = [
    hubPoolStore.address,
    USDC[chainId],
    L1_ADDRESS_MAP[chainId].cctpTokenMessenger,
    CIRCLE_DOMAIN_IDs[SPOKE_CHAIN_ID],
  ];
  const instance = await deployments.deploy("Universal_Adapter", {
    from: deployer,
    log: true,
    skipIfAlreadyDeployed: false,
    args,
  });
  await hre.run("verify:verify", { address: instance.address, constructorArguments: args });
};

module.exports = func;
func.tags = ["UniversalStorageProofAdapter"];
