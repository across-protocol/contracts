import { DeployFunction } from "hardhat-deploy/types";
import { getOftEid, toWei } from "../utils/utils";
import { HardhatRuntimeEnvironment } from "hardhat/types";
import { CIRCLE_DOMAIN_IDs, L1_ADDRESS_MAP, USDC, ZERO_ADDRESS } from "./consts";
import { CCTP_NO_DOMAIN } from "@across-protocol/constants";
import { CIRCLE_UNINITIALIZED_DOMAIN_ID } from "./consts";
import assert from "assert";
import { getDeployedAddress } from "../src/DeploymentUtils";

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { SPOKE_CHAIN_ID } = process.env;
  assert(SPOKE_CHAIN_ID, "SPOKE_CHAIN_ID is required");

  const { deployer } = await hre.getNamedAccounts();
  const chainId = parseInt(await hre.getChainId());

  // Warning: re-using the same HubPoolStore for different L2's is only safe if the L2 spoke pools have
  // unique addresses, since the relayed message `targets` are part of the unique data hash.
  const hubPoolStore = getDeployedAddress("HubPoolStore", chainId);

  // todo: implement similar treatment to `CIRCLE_DOMAIN_IDs`
  const oftDstEid = getOftEid(Number(SPOKE_CHAIN_ID));
  const oftFeeCap = toWei("1"); // 1 eth transfer fee cap
  const adapterStore = getDeployedAddress("AdapterStore", chainId);

  const cctpDomainId = CIRCLE_DOMAIN_IDs[Number(SPOKE_CHAIN_ID)] ?? CCTP_NO_DOMAIN;
  const args = [
    hubPoolStore,
    USDC[chainId],
    // ! Notice: pick `cctpV2TokenMessenger` / `cctpTokenMessenger` here to match your spoke CCTP version
    cctpDomainId === CCTP_NO_DOMAIN ? ZERO_ADDRESS : L1_ADDRESS_MAP[chainId].cctpV2TokenMessenger,
    cctpDomainId === CCTP_NO_DOMAIN ? CIRCLE_UNINITIALIZED_DOMAIN_ID : cctpDomainId,
    adapterStore,
    oftDstEid,
    oftFeeCap,
  ];
  const instance = await hre.deployments.deploy("Universal_Adapter", {
    from: deployer,
    log: true,
    skipIfAlreadyDeployed: false,
    args,
  });
  await hre.run("verify:verify", { address: instance.address, constructorArguments: args });
};

module.exports = func;
func.tags = ["UniversalAdapter"];
