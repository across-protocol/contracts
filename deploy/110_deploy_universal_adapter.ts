import { DeployFunction } from "hardhat-deploy/types";
import { HardhatRuntimeEnvironment } from "hardhat/types";
import { CIRCLE_DOMAIN_IDs, L1_ADDRESS_MAP, USDC, ZERO_ADDRESS } from "./consts";
import assert from "assert";

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { SPOKE_CHAIN_ID } = process.env;
  assert(SPOKE_CHAIN_ID, "SPOKE_CHAIN_ID is required");

  const { deployer } = await hre.getNamedAccounts();
  const chainId = parseInt(await hre.getChainId());

  // Warning: re-using the same HubPoolStore for different L2's is only safe if the L2 spoke pools have
  // unique addresses, since the relayed message `targets` are part of the unique data hash.
  const hubPoolStore = await hre.deployments.get("HubPoolStore");

  const args = [
    hubPoolStore.address,
    USDC[chainId],
    CIRCLE_DOMAIN_IDs[SPOKE_CHAIN_ID] ? L1_ADDRESS_MAP[chainId].cctpTokenMessenger : ZERO_ADDRESS,
    CIRCLE_DOMAIN_IDs[SPOKE_CHAIN_ID] ?? 4294967295, // maxUint32,
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
func.tags = ["UniversalAdapter"];
