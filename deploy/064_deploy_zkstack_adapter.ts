import assert from "assert";
import { HardhatRuntimeEnvironment } from "hardhat/types";
import { DeployFunction } from "hardhat-deploy/types";
import {
  L1_ADDRESS_MAP,
  USDC,
  WETH,
  ZERO_ADDRESS,
  CIRCLE_UNINITIALIZED_DOMAIN_ID,
  ZK_L2_GAS_LIMIT,
  ZK_L1_GAS_TO_L2_GAS_PER_PUBDATA_LIMIT,
  ZK_MAX_GASPRICE,
} from "./consts";

/**
 * Note:
 * This adapter supports ZkStack L2s.
 *
 * Usage:
 * $ SPOKE_CHAIN_ID=37111 yarn hardhat deploy --network sepolia --tags ZkStackCustomGasTokenAdapter
 */

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  // Excess bridge fees will go to this address on L2.
  const L2_REFUND_ADDRESS = "0x07aE8551Be970cB1cCa11Dd7a11F47Ae82e70E67";

  const { SPOKE_CHAIN_ID } = process.env;
  assert(SPOKE_CHAIN_ID !== undefined, "SPOKE_CHAIN_ID not defined in environment");
  assert(
    parseInt(SPOKE_CHAIN_ID).toString() === SPOKE_CHAIN_ID,
    "SPOKE_CHAIN_ID (${SPOKE_CHAIN_ID}) must be an integer"
  );

  const { deployer } = await hre.getNamedAccounts();
  const chainId = parseInt(await hre.getChainId());

  const constructorArguments = [
    SPOKE_CHAIN_ID,
    L1_ADDRESS_MAP[chainId].zkBridgeHub,
    USDC[chainId],
    L1_ADDRESS_MAP[chainId][`zkUsdcSharedBridge_${SPOKE_CHAIN_ID}`],
    ZERO_ADDRESS,
    CIRCLE_UNINITIALIZED_DOMAIN_ID,
    WETH[chainId],
    L2_REFUND_ADDRESS,
    ZK_L2_GAS_LIMIT,
    ZK_L1_GAS_TO_L2_GAS_PER_PUBDATA_LIMIT,
    ZK_MAX_GASPRICE,
  ];

  const { address: deployment } = await hre.deployments.deploy("ZkStack_Adapter", {
    from: deployer,
    log: true,
    skipIfAlreadyDeployed: true,
    args: constructorArguments,
  });

  await hre.run("verify:verify", { address: deployment, constructorArguments });
};

module.exports = func;
func.tags = ["ZkStackAdapter", "mainnet"];
