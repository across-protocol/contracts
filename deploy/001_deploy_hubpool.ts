import { DeployFunction } from "hardhat-deploy/types";
import { HardhatRuntimeEnvironment } from "hardhat/types";
import { L1_ADDRESS_MAP, WETH, ZERO_ADDRESS } from "./consts";

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployments: { deploy }, getNamedAccounts, getChainId } = hre;
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
      ZERO_ADDRESS,
    ],
    libraries: { MerkleLib: lpTokenFactory.address },
  });
};
module.exports = func;
func.tags = ["HubPool", "mainnet"];
