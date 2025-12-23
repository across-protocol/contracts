import { DeployFunction } from "hardhat-deploy/types";
import { HardhatRuntimeEnvironment } from "hardhat/types";
import { verifyContract } from "../utils/utils.hre";

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployer } = await hre.getNamedAccounts();

  const deployment = await hre.deployments.deploy("SpokePoolVerifier", {
    from: deployer,
    log: true,
    skipIfAlreadyDeployed: true,
    deterministicDeployment: "0x1234", // Salt for the create2 call.
  });
  console.log(`Deployed at block ${deployment.receipt.blockNumber} (tx: ${deployment.transactionHash})`);
  await verifyContract(deployment.address, []);
};

module.exports = func;
func.tags = ["SpokePoolVerifier"];
