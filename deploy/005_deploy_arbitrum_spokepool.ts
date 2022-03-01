const func = async function (hre: any) {
  const { deployments, getNamedAccounts, companionNetworks } = hre;
  const { deploy } = deployments;

  const { deployer } = await getNamedAccounts();

  // Grab L1 addresses:
  const { deployments: l1Deployments } = companionNetworks.l1;
  const adapter = await l1Deployments.get("Arbitrum_Adapter");
  console.log(`Using l1 adapter @ ${adapter.address}`);
  const hubPool = await l1Deployments.get("HubPool");
  console.log(`Using l1 hub pool @ ${hubPool.address}`);

  await deploy("Arbitrum_SpokePool", {
    from: deployer,
    log: true,
    skipIfAlreadyDeployed: true,
    args: [
      "0x9413AD42910c1eA60c737dB5f58d1C504498a3cD", //_l2GatewayRouter
      adapter.address, // Set adapter as cross domain admin
      hubPool.address,
      "0xB47e6A5f8b33b3F17603C83a0535A9dcD7E32681", // l2Weth
      "0x0000000000000000000000000000000000000000",
    ],
  });
};
module.exports = func;
func.tags = ["arbitrum-spokepool"];
