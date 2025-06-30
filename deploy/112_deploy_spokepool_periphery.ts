import { DeployFunction } from "hardhat-deploy/types";
import { HardhatRuntimeEnvironment } from "hardhat/types";
import { L1_ADDRESS_MAP, L2_ADDRESS_MAP } from "./consts";
import { CHAIN_IDs } from "@across-protocol/constants";

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const contractName = "SpokePoolPeriphery";
  const { deployer } = await hre.getNamedAccounts();
  const chainId = parseInt(await hre.getChainId());

  const isMainnet = [CHAIN_IDs.MAINNET, CHAIN_IDs.SEPOLIA].includes(chainId);
  const permit2Address = isMainnet ? L1_ADDRESS_MAP[chainId].permit2 : L2_ADDRESS_MAP[chainId].permit2;

  if (!permit2Address) {
    throw new Error(`Permit2 address not found for chain ${chainId}`);
  }

  const constructorArgs = [permit2Address];

  const deployment = await hre.deployments.deploy("SpokePoolPeriphery", {
    contract: contractName,
    from: deployer,
    log: true,
    skipIfAlreadyDeployed: true,
    deterministicDeployment: "0x1235", // Salt for the create2 call.
    args: constructorArgs,
  });

  await hre.run("verify:verify", {
    address: deployment.address,
    constructorArguments: constructorArgs,
  });
};
module.exports = func;
func.tags = ["SpokePoolPeriphery"];
