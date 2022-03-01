import { L1_ADDRESS_MAP } from "./consts";

const func = async function (hre: any) {
  const { deployments, getNamedAccounts, getChainId } = hre;
  const { deploy } = deployments;

  const { deployer } = await getNamedAccounts();

  const chainId = await getChainId();

  const lpTokenFactory = await deploy("LpTokenFactory", { from: deployer, log: true, skipIfAlreadyDeployed: true });

  await deploy("HubPool", {
    from: deployer,
    log: true,
    skipIfAlreadyDeployed: true,
    args: [
      lpTokenFactory.address,
      L1_ADDRESS_MAP[chainId].finder,
      L1_ADDRESS_MAP[chainId].weth,
      "0x0000000000000000000000000000000000000000",
    ],
    libraries: { MerkleLib: lpTokenFactory.address },
  });
};
module.exports = func;
func.tags = ["hubpool"];
