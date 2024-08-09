import { DeployFunction } from "hardhat-deploy/types";
import { HardhatRuntimeEnvironment } from "hardhat/types";
import { TOKEN_SYMBOLS_MAP } from "../utils";
import { L1_ADDRESS_MAP, USDC, WETH } from "./consts";

const MATIC = TOKEN_SYMBOLS_MAP.MATIC.addresses;

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployments: { deploy }, getNamedAccounts, getChainId } = hre;
  const { deployer } = await getNamedAccounts();
  const chainId = parseInt(await getChainId());

  const args = [
    L1_ADDRESS_MAP[chainId].polygonRootChainManager,
    L1_ADDRESS_MAP[chainId].polygonFxRoot,
    L1_ADDRESS_MAP[chainId].polygonDepositManager,
    L1_ADDRESS_MAP[chainId].polygonERC20Predicate,
    MATIC[chainId],
    WETH[chainId],
    USDC[chainId],
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
