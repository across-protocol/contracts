import { DeployFunction } from "hardhat-deploy/types";
import { L1_ADDRESS_MAP } from "./consts";
import { HardhatRuntimeEnvironment } from "hardhat/types";

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployments, getNamedAccounts, getChainId } = hre;
  const { deploy } = deployments;

  const { deployer } = await getNamedAccounts();

  const chainId = parseInt(await getChainId());

  const args = [
    L1_ADDRESS_MAP[chainId].polygonRootChainManager,
    L1_ADDRESS_MAP[chainId].polygonFxRoot,
    L1_ADDRESS_MAP[chainId].polygonDepositManager,
    L1_ADDRESS_MAP[chainId].polygonERC20Predicate,
    L1_ADDRESS_MAP[chainId].matic,
    L1_ADDRESS_MAP[chainId].weth,
    L1_ADDRESS_MAP[chainId].usdc,
    L1_ADDRESS_MAP[chainId].cctpTokenMessenger,
  ];
  const instance = await deploy("Polygon_Adapter", {
    from: deployer,
    log: true,
    skipIfAlreadyDeployed: false,
    args,
  });
  await run("verify:verify", { address: instance.address, constructorArguments: args });
};

module.exports = func;
func.tags = ["PolygonAdapter", "mainnet"];
