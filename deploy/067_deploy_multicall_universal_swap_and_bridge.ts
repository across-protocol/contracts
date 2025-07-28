import { DeployFunction } from "hardhat-deploy/types";
import { HardhatRuntimeEnvironment } from "hardhat/types";

import { getDeployedAddress } from "../src/DeploymentUtils";
import { CHAIN_IDs } from "@across-protocol/constants";
import { L1_ADDRESS_MAP } from "./consts";

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployer } = await hre.getNamedAccounts();
  const chainId = parseInt(await hre.getChainId());

  await hre.deployments.deploy("Multicall3_UniversalSwapAndBridge", {
    contract: "UniversalSwapAndBridge",
    from: deployer,
    log: true,
    skipIfAlreadyDeployed: false,
    deterministicDeployment: "0x123456789abc", // Salt for the create2 call.
    args: [
      getDeployedAddress("SpokePool", chainId),
      chainId === CHAIN_IDs.MAINNET ? L1_ADDRESS_MAP[chainId].multicall3 : L1_ADDRESS_MAP[chainId].multicall3,
      // Allows function selectors in Multicall3:
      // - aggregate
      // - aggregate3
      // https://etherscan.io/address/0xcA11bde05977b3631167028862bE2a173976CA11#writeContract
      ["0x252dba42", "0x82ad56cb"],
    ],
  });
};
module.exports = func;
func.tags = ["Multicall3_UniversalSwapAndBridge", "UniversalSwapAndBridge", "multicall3"];
