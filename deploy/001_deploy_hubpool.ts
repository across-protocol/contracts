import { L1_ADDRESS_MAP, WETH } from "./consts";
import { DeployFunction } from "hardhat-deploy/types";
import { HardhatRuntimeEnvironment } from "hardhat/types";

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployments, getNamedAccounts, getChainId } = hre;
  const { deploy } = deployments;

  const { deployer } = await getNamedAccounts();

  const chainId = parseInt(await getChainId());

  const lpTokenFactory = await deploy("LpTokenFactory", { from: deployer, log: true, skipIfAlreadyDeployed: true });

  await deploy("HubPool", {
    from: deployer,
    log: true,
    skipIfAlreadyDeployed: true,
    args: [
      lpTokenFactory.address,
      L1_ADDRESS_MAP[chainId].finder,
      WETH[chainId],
      "0x0000000000000000000000000000000000000000",
    ],
    libraries: { MerkleLib: lpTokenFactory.address },
  });
};
module.exports = func;
func.tags = ["HubPool", "mainnet"];
