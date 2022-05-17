import "hardhat-deploy";
import { HardhatRuntimeEnvironment } from "hardhat/types/runtime";

const func = async function (hre: HardhatRuntimeEnvironment) {
  const { deployments, getNamedAccounts, companionNetworks } = hre;
  const { deploy } = deployments;

  const { deployer } = await getNamedAccounts();

  // Grab L1 addresses:
  const { deployments: l1Deployments } = companionNetworks.l1;
  const hubPool = await l1Deployments.get("HubPool");
  console.log(`Using l1 hub pool @ ${hubPool.address}`);

  // Boba Spoke pool uses the same implementation as optimism, with no changes.
  await deploy("Boba_SpokePool", {
    from: deployer,
    log: true,
    skipIfAlreadyDeployed: true,
    args: [
      hubPool.address, // Set hub pool as cross domain admin since it delegatecalls the Optimism_Adapter logic.
      hubPool.address,
      "0x0000000000000000000000000000000000000000", // timer
    ],
  });
};
module.exports = func;
func.tags = ["BobaSpokePool", "boba"];
