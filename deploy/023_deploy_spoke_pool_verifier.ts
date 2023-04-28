import { DeployFunction } from "hardhat-deploy/types";
import { HardhatRuntimeEnvironment } from "hardhat/types";

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployments, getNamedAccounts } = hre;
  const { deploy } = deployments;

  const { deployer } = await getNamedAccounts();

  await deploy("SpokePoolVerifier", {
    from: deployer,
    log: true,
    skipIfAlreadyDeployed: true,
    deterministicDeployment: "0x1234", // Salt for the create2 call.
  });
};

module.exports = func;
func.tags = ["SpokePoolVerifier", "polygon", "mainnet", "optimism", "arbitrum", "zksync"];
