const func = async function (hre: any) {
  const { deployments, getNamedAccounts } = hre;
  const { deploy } = deployments;

  const { deployer } = await getNamedAccounts();

  console.log("deployer", deployer);

  const lpTokenFactory = await deploy("LpTokenFactory", { from: deployer, log: true, skipIfAlreadyDeployed: true });
  console.log("lpTokenFactory", lpTokenFactory.address);

  await deploy("HubPool", {
    from: deployer,
    log: true,
    skipIfAlreadyDeployed: true,
    args: [
      lpTokenFactory.address,
      "0xeD0169a88d267063184b0853BaAAAe66c3c154B2", // finder
      "0xd0A1E359811322d97991E03f863a0C30C2cF029C", // weth
      "0x0000000000000000000000000000000000000000",
    ],
    libraries: { MerkleLib: lpTokenFactory.address },
  });
};
module.exports = func;
func.tags = ["hubpool"];
