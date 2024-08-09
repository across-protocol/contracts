import { DeployFunction } from "hardhat-deploy/types";
import { HardhatRuntimeEnvironment } from "hardhat/types";

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployer } = await hre.getNamedAccounts();

  const deployment = await hre.deployments.deploy("SpokePoolVerifier", {
    from: deployer,
    log: true,
    skipIfAlreadyDeployed: true,
    deterministicDeployment: "0x1234", // Salt for the create2 call.
  });
  console.log(`Deployed at block ${deployment.receipt.blockNumber} (tx: ${deployment.transactionHash})`);
  await hre.run("verify:verify", { address: deployment.address, constructorArguments: [] });
};

module.exports = func;
func.tags = ["SpokePoolVerifier"];
