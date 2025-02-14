import { DeployFunction } from "hardhat-deploy/types";
import { HardhatRuntimeEnvironment } from "hardhat/types";
import { CHAIN_IDs } from "../utils";
import { L1_ADDRESS_MAP, OP_STACK_ADDRESS_MAP, USDC, WETH } from "./consts";
import assert from "assert";

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { SPOKE_CHAIN_ID = CHAIN_IDs.UNICHAIN } = process.env;
  assert(
    [CHAIN_IDs.UNICHAIN_SEPOLIA, CHAIN_IDs.UNICHAIN].includes(parseInt(SPOKE_CHAIN_ID)),
    "SPOKE_CHAIN_ID must be either UNICHAIN_SEPOLIA or UNICHAIN"
  );

  const { deployer } = await hre.getNamedAccounts();
  const chainId = parseInt(await hre.getChainId());
  const opStack = OP_STACK_ADDRESS_MAP[chainId][SPOKE_CHAIN_ID];

  const args = [
    WETH[chainId],
    opStack.L1CrossDomainMessenger,
    opStack.L1StandardBridge,
    USDC[chainId],
    L1_ADDRESS_MAP[chainId].cctpTokenMessenger,
  ];

  const instance = await hre.deployments.deploy("DoctorWho_Adapter", {
    from: deployer,
    log: true,
    skipIfAlreadyDeployed: false,
    args,
  });
  await hre.run("verify:verify", { address: instance.address, constructorArguments: args });
};

module.exports = func;
func.tags = ["DoctorWhoAdapter", "doctorwho"];
