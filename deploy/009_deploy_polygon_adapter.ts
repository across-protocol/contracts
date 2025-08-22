import { DeployFunction } from "hardhat-deploy/types";
import { HardhatRuntimeEnvironment } from "hardhat/types";
import { CHAIN_IDs, TOKEN_SYMBOLS_MAP } from "../utils";
import { getOftEid, toWei } from "../utils/utils";
import { L1_ADDRESS_MAP, USDC, WETH } from "./consts";

const MATIC = TOKEN_SYMBOLS_MAP.MATIC.addresses;

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployer } = await hre.getNamedAccounts();
  const chainId = parseInt(await hre.getChainId());

  const spokeChainId = chainId == CHAIN_IDs.MAINNET ? CHAIN_IDs.POLYGON : CHAIN_IDs.POLYGON_AMOY;

  const oftDstEid = getOftEid(spokeChainId);
  const oftFeeCap = toWei("1"); // 1 eth transfer fee cap

  const args = [
    L1_ADDRESS_MAP[chainId].polygonRootChainManager,
    L1_ADDRESS_MAP[chainId].polygonFxRoot,
    L1_ADDRESS_MAP[chainId].polygonDepositManager,
    L1_ADDRESS_MAP[chainId].polygonERC20Predicate,
    MATIC[chainId],
    WETH[chainId],
    USDC[chainId],
    L1_ADDRESS_MAP[chainId].cctpTokenMessenger,
    L1_ADDRESS_MAP[chainId].adapterStore,
    oftDstEid,
    oftFeeCap,
  ];
  const instance = await hre.deployments.deploy("Polygon_Adapter", {
    from: deployer,
    log: true,
    skipIfAlreadyDeployed: false,
    args,
  });
  await hre.run("verify:verify", { address: instance.address, constructorArguments: args });
};

module.exports = func;
func.tags = ["PolygonAdapter", "mainnet"];
