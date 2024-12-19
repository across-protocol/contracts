import assert from "assert";
import { HardhatRuntimeEnvironment } from "hardhat/types";
import { DeployFunction } from "hardhat-deploy/types";
import { OP_STACK_ADDRESS_MAP, USDC, WETH } from "./consts";

/**
 * Note:
 * Both the spoke pool periphery and periphery proxy need to know each other's address. Since the periphery generally contains
 * the most logic, the periphery is deployed atomically with the create2factory, while the periphery proxy is deployed asynchronously.
 * yarn hardhat deploy --network mainnet --tags SpokePoolPeripheryProxy
 */

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployer } = await hre.getNamedAccounts();
  const chainId = parseInt(await hre.getChainId());

  const { address: deployment } = await hre.deployments.deploy("SpokePoolPeripheryProxy", {
    from: deployer,
    log: true,
    skipIfAlreadyDeployed: true,
    deterministicDeployment: "0x1234567890",
    args: [],
  });

  await hre.run("verify:verify", { address: deployment });
};

module.exports = func;
func.tags = ["SpokePoolPeripheryProxy"];
