import { DeployFunction } from "hardhat-deploy/types";
import { HardhatRuntimeEnvironment } from "hardhat/types";

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployments, getNamedAccounts } = hre;
  const { deploy } = deployments;

  const { deployer } = await getNamedAccounts();

  // Deploy from EOA for convenience
  // Grant default admin role to new admin
  // revoke role from deployer
  await deploy("PermissionSplitterProxy", {
    from: deployer,
    log: true,
    skipIfAlreadyDeployed: true,
    args: [],
  });
};

module.exports = func;
func.tags = ["MintableERC1155"];
