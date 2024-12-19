import assert from "assert";
import { HardhatRuntimeEnvironment } from "hardhat/types";
import { DeployFunction } from "hardhat-deploy/types";

/**
 * Usage:
 * $ yarn hardhat deploy --network mainnet --tags Create2Factory
 */

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployer } = await hre.getNamedAccounts();
  const chainId = parseInt(await hre.getChainId());

  const { address: deployment } = await hre.deployments.deploy("Create2Factory", {
    from: deployer,
    log: true,
    skipIfAlreadyDeployed: true,
    args: [],
    deterministicDeployment: "0x12345678",
    maxPriorityFeePerGas: 1,
    maxFeePerGas: 10e9,
  });

  await hre.run("verify:verify", { address: deployment });
};

module.exports = func;
func.tags = ["Create2Factory"];
