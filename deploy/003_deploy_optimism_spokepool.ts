const func = async function (hre: any) {
  const { deployments, getNamedAccounts, companionNetworks } = hre;
  const { deploy } = deployments;

  const { deployer } = await getNamedAccounts();

  // TODO: This part is not quite working, throwing:
  // "HardhatError: HH101: Hardhat was set to use chain id 42, but connected to a chain with id 69."
  // Grab L1 addresses:
  const { deployments: l1Deployments } = companionNetworks.l1;
  const adapter = await l1Deployments.get("Optimism_Adapter");
  console.log(`Using l1 adapter @ ${adapter.address}`);
  const hubPool = await l1Deployments.get("HubPool");
  console.log(`Using l1 adapter @ ${hubPool.address}`);

  await deploy("SpokePool", {
    from: deployer,
    log: true,
    skipIfAlreadyDeployed: true,
    args: [
      adapter.address, // Set adapter as cross domain admin
      hubPool.address,
      "0x0000000000000000000000000000000000000000",
    ],
  });
};
module.exports = func;
func.tags = ["optimism-spokepool"];
