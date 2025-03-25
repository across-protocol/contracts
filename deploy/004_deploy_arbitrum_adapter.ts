import { CHAIN_IDs } from "@across-protocol/constants";
import { toWei } from "../utils/utils";
import { L1_ADDRESS_MAP, USDC } from "./consts";
import { DeployFunction } from "hardhat-deploy/types";
import { HardhatRuntimeEnvironment } from "hardhat/types";

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployer } = await hre.getNamedAccounts();
  const chainId = parseInt(await hre.getChainId());

  // This address receives gas refunds on the L2 after messages are relayed. Currently
  // set to the Risk Labs relayer address. The deployer should change this if necessary.
  const l2RefundAddress = "0x07aE8551Be970cB1cCa11Dd7a11F47Ae82e70E67";

  // Source https://docs.layerzero.network/v2/deployments/deployed-contracts
  const oftArbitrumEid = chainId == CHAIN_IDs.MAINNET ? 30110 : 40231;
  const oftFeeCap = toWei("1"); // 1 eth transfer fee cap

  // Source https://github.com/hyperlane-xyz/hyperlane-registry/tree/main/chains
  const hypXERC20ArbitrumDomain = chainId == CHAIN_IDs.MAINNET ? 42161 : 421614;
  const hypXERC20FeeCap = toWei("1"); // 1 eth transfer fee cap

  const args = [
    L1_ADDRESS_MAP[chainId].l1ArbitrumInbox,
    L1_ADDRESS_MAP[chainId].l1ERC20GatewayRouter,
    l2RefundAddress,
    USDC[chainId],
    L1_ADDRESS_MAP[chainId].cctpTokenMessenger,
    L1_ADDRESS_MAP[chainId].adapterStore,
    oftArbitrumEid,
    oftFeeCap,
    hypXERC20ArbitrumDomain,
    hypXERC20FeeCap,
  ];
  const instance = await hre.deployments.deploy("Arbitrum_Adapter", {
    from: deployer,
    log: true,
    skipIfAlreadyDeployed: false,
    args: [
      L1_ADDRESS_MAP[chainId].l1ArbitrumInbox,
      L1_ADDRESS_MAP[chainId].l1ERC20GatewayRouter,
      l2RefundAddress,
      USDC[chainId],
      L1_ADDRESS_MAP[chainId].cctpTokenMessenger,
      L1_ADDRESS_MAP[chainId].adapterStore,
      oftArbitrumEid,
      oftFeeCap,
      hypXERC20ArbitrumDomain,
      hypXERC20FeeCap,
    ],
  });
  await hre.run("verify:verify", { address: instance.address, constructorArguments: args });
};

module.exports = func;
func.tags = ["ArbitrumAdapter", "mainnet"];
