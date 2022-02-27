const func = async function (hre: any) {
  const { deployments, getNamedAccounts } = hre;
  const { deploy, get } = deployments;

  const { deployer } = await getNamedAccounts();

  const hubPoolAddress = (await get("HubPool")).address;

  await deploy("Ethereum_Adapter", {
    from: deployer,
    log: true,
    skipIfAlreadyDeployed: true,
    args: [hubPoolAddress],
  });
};

module.exports = func;
func.dependencies = ["HubPool"];
func.tags = ["ethereum-adapter"];
