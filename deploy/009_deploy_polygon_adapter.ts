import { DeployFunction } from "hardhat-deploy/types";
import { L1_ADDRESS_MAP } from "./consts";
import { HardhatRuntimeEnvironment } from "hardhat/types";
import { ZERO_ADDRESS } from "@uma/common";

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployments, getNamedAccounts, getChainId } = hre;
  const { deploy } = deployments;

  const { deployer } = await getNamedAccounts();

  const chainId = parseInt(await getChainId());

  await deploy("Polygon_Adapter", {
    from: deployer,
    log: true,
    skipIfAlreadyDeployed: false,
    args: [
      L1_ADDRESS_MAP[chainId].polygonRootChainManager,
      L1_ADDRESS_MAP[chainId].polygonFxRoot,
      L1_ADDRESS_MAP[chainId].polygonDepositManager,
      L1_ADDRESS_MAP[chainId].polygonERC20Predicate,
      L1_ADDRESS_MAP[chainId].matic,
      L1_ADDRESS_MAP[chainId].weth,
      L1_ADDRESS_MAP[chainId].l1UsdcAddress,
      // L1_ADDRESS_MAP[chainId].cctpTokenMessenger,
      // For now, we are not using the CCTP bridge and can disable by setting
      // the cctpTokenMessenger to the zero address.
      ZERO_ADDRESS,
    ],
  });
};

module.exports = func;
func.tags = ["PolygonAdapter", "mainnet"];
