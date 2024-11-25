import { DeployFunction } from "hardhat-deploy/types";
import { HardhatRuntimeEnvironment } from "hardhat/types";

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployer } = await hre.getNamedAccounts();

  await hre.deployments.deploy("DonationBox", {
    contract: "DonationBox",
    from: deployer,
    log: true,
    skipIfAlreadyDeployed: true,
    args: [],
  });
};
module.exports = func;
func.tags = ["DonationBox"];
