import assert from "assert";
import { HardhatRuntimeEnvironment } from "hardhat/types";
import { DeployFunction } from "hardhat-deploy/types";
import { OP_STACK_ADDRESS_MAP, USDC, WETH } from "./consts";

/**
 * Note:
 * This adapter supports OP stack L2s with Circle Bridged USDC.
 * Do not deploy this adapter if the OP L2 uses OP bridged USDC.
 * It is _not_ currently suitable for CCTP deployments because the CCTP messenger address is set to 0x0.
 *
 * Usage:
 * $ SPOKE_CHAIN_ID=10 yarn hardhat deploy --network mainnet --tags OpAdapter
 */

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { SPOKE_CHAIN_ID } = process.env;
  assert(SPOKE_CHAIN_ID !== undefined, "SPOKE_CHAIN_ID not defined in environment");
  assert(
    parseInt(SPOKE_CHAIN_ID).toString() === SPOKE_CHAIN_ID,
    "SPOKE_CHAIN_ID (${SPOKE_CHAIN_ID}) must be an integer"
  );

  const { deployer } = await hre.getNamedAccounts();
  const chainId = parseInt(await hre.getChainId());

  const constructorArguments = [
    WETH[chainId],
    USDC[chainId],
    OP_STACK_ADDRESS_MAP[chainId][SPOKE_CHAIN_ID].L1CrossDomainMessenger,
    OP_STACK_ADDRESS_MAP[chainId][SPOKE_CHAIN_ID].L1StandardBridge,
    OP_STACK_ADDRESS_MAP[chainId][SPOKE_CHAIN_ID].L1OpUSDCBridgeAdapter,
  ];

  const { address: deployment } = await hre.deployments.deploy("OP_Adapter", {
    from: deployer,
    log: true,
    skipIfAlreadyDeployed: true,
    args: constructorArguments,
  });

  await hre.run("verify:verify", { address: deployment, constructorArguments });
};

module.exports = func;
func.tags = ["OpAdapter", "mainnet"];
