import { L1_ADDRESS_MAP, WETH } from "./consts";
import { DeployFunction } from "hardhat-deploy/types";
import { HardhatRuntimeEnvironment } from "hardhat/types";
import { CHAIN_IDs } from "../utils";
import assert from "assert";
import { toWei } from "../utils/utils";

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployer } = await hre.getNamedAccounts();
  const chainId = parseInt(await hre.getChainId());

  assert(
    chainId == CHAIN_IDs.MAINNET,
    "We only support deploying Linea Adapter on Mainnet for now. To deploy on testnet, update consts and configs."
  );

  // Pick correct destination chain id to set based on deployment network
  const dstChainId = chainId == CHAIN_IDs.MAINNET ? CHAIN_IDs.LINEA : undefined;

  // Set the Hyperlane xERC20 destination domain based on the chain https://github.com/hyperlane-xyz/hyperlane-registry/tree/main/chains
  const hypXERC20DstDomain = chainId == CHAIN_IDs.MAINNET ? 59144 : undefined;

  // 1 ether is our default Hyperlane xERC20 fee cap on chains with ETH as gas token
  const hypXERC20FeeCap = toWei("1");

  await hre.deployments.deploy("Linea_Adapter", {
    from: deployer,
    log: true,
    skipIfAlreadyDeployed: true,
    args: [
      WETH[chainId],
      L1_ADDRESS_MAP[chainId].lineaMessageService,
      L1_ADDRESS_MAP[chainId].lineaTokenBridge,
      L1_ADDRESS_MAP[chainId].lineaUsdcBridge,
      dstChainId,
      L1_ADDRESS_MAP[chainId].adapterStore,
      hypXERC20DstDomain,
      hypXERC20FeeCap,
    ],
  });
};

module.exports = func;
func.dependencies = ["HubPool"];
func.tags = ["LineaAdapter", "mainnet"];
