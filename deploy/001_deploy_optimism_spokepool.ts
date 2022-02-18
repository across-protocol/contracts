const func = async function (hre: any) {
  const { deployments, getNamedAccounts } = hre;
  const { deploy } = deployments;

  const { deployer } = await getNamedAccounts();

  console.log("deployer", deployer);

  await deploy("Optimism_SpokePool", {
    from: deployer,
    log: true,
    skipIfAlreadyDeployed: true,
    args: [
      "0xdeaddeaddeaddeaddeaddeaddeaddeaddead0000",
      deployer, // cross domain admin
      "0xA393cC1C3aE00d9a532B425faF984dF608306119", // hubpool
      "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2", // weth
      "0x0000000000000000000000000000000000000000",
    ],
  });
};
module.exports = func;
func.tags = ["optimism_spoke_pool"];
