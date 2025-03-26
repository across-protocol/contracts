import { L1_ADDRESS_MAP, WETH } from "./consts";
import { DeployFunction } from "hardhat-deploy/types";
import { HardhatRuntimeEnvironment } from "hardhat/types";
import { CHAIN_IDs } from "../utils";
import assert from "assert";
import { getHyperlaneDomainId, toWei } from "../utils/utils";

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployer } = await hre.getNamedAccounts();
  const chainId = parseInt(await hre.getChainId());

  // TODO: If you remove this assert, also update `const spokeChainId` below
  assert(
    chainId == CHAIN_IDs.MAINNET,
    "We only support deploying Linea Adapter on Mainnet for now. To deploy on testnet, set CHAIN_IDs.LINEA_SEPOLIA."
  );

  const spokeChainId = CHAIN_IDs.LINEA;
  const hyperlaneDstDomain = getHyperlaneDomainId(spokeChainId);
  const hyperlaneXERC20FeeCap = toWei("1"); // 1 eth transfer fee cap

  await hre.deployments.deploy("Linea_Adapter", {
    from: deployer,
    log: true,
    skipIfAlreadyDeployed: true,
    args: [
      WETH[chainId],
      L1_ADDRESS_MAP[chainId].lineaMessageService,
      L1_ADDRESS_MAP[chainId].lineaTokenBridge,
      L1_ADDRESS_MAP[chainId].lineaUsdcBridge,
      L1_ADDRESS_MAP[chainId].adapterStore,
      hyperlaneDstDomain,
      hyperlaneXERC20FeeCap,
    ],
  });
};

module.exports = func;
func.dependencies = ["HubPool"];
func.tags = ["LineaAdapter", "mainnet"];
