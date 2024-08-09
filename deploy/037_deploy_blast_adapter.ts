import { DeployFunction } from "hardhat-deploy/types";
import { HardhatRuntimeEnvironment } from "hardhat/types";
import { TOKEN_SYMBOLS_MAP } from "../utils";
import { L1_ADDRESS_MAP, USDC, WETH } from "./consts";

const USDB = TOKEN_SYMBOLS_MAP.USDB.addresses;

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployments: { deploy }, getNamedAccounts, getChainId } = hre;
  const { deployer } = await getNamedAccounts();
  const chainId = parseInt(await getChainId());

  await deploy("Blast_Adapter", {
    from: deployer,
    log: true,
    skipIfAlreadyDeployed: true,
    args: [
      WETH[chainId],
      L1_ADDRESS_MAP[chainId].blastCrossDomainMessenger,
      L1_ADDRESS_MAP[chainId].blastStandardBridge,
      USDC[chainId],
      L1_ADDRESS_MAP[chainId].l1BlastBridge,
      USDB[chainId],
      "200_000",
    ],
  });
};

module.exports = func;
func.dependencies = ["HubPool"];
func.tags = ["BlastAdapter", "mainnet"];
