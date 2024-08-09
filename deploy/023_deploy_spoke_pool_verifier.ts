import { DeployFunction } from "hardhat-deploy/types";
import { HardhatRuntimeEnvironment } from "hardhat/types";

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployments: { deploy }, getNamedAccounts } = hre;
  const { deployer } = await getNamedAccounts();

  const deployment = await deploy("SpokePoolVerifier", {
    from: deployer,
    log: true,
    skipIfAlreadyDeployed: true,
    deterministicDeployment: "0x1234", // Salt for the create2 call.
  });
  console.log(`Deployed at block ${deployment.receipt.blockNumber} (tx: ${deployment.transactionHash})`);
  await run("verify:verify", { address: deployment.address, constructorArguments: [] });
};

module.exports = func;
func.tags = ["SpokePoolVerifier"];
