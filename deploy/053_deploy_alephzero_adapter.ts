import { L1_ADDRESS_MAP, ZERO_ADDRESS, AZERO, ARBITRUM_MAX_SUBMISSION_COST, AZERO_GAS_PRICE } from "./consts";
import { DeployFunction } from "hardhat-deploy/types";
import { HardhatRuntimeEnvironment } from "hardhat/types";

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployer } = await hre.getNamedAccounts();
  const chainId = parseInt(await hre.getChainId());

  // This address receives gas refunds on the L2 after messages are relayed. Currently
  // set to the Risk Labs relayer address. The deployer should change this if necessary.
  const l2RefundAddress = "0x07aE8551Be970cB1cCa11Dd7a11F47Ae82e70E67";

  const args = [
    L1_ADDRESS_MAP[chainId].l1AlephZeroInbox,
    L1_ADDRESS_MAP[chainId].l1AlephZeroERC20GatewayRouter,
    l2RefundAddress,
    ZERO_ADDRESS,
    ZERO_ADDRESS,
    0, // No Circle CCTP domain ID.
    L1_ADDRESS_MAP[chainId].donationBox,
    AZERO.decimals,
    ARBITRUM_MAX_SUBMISSION_COST,
    AZERO_GAS_PRICE,
  ];
  const instance = await hre.deployments.deploy("Arbitrum_CustomGasToken_Adapter", {
    from: deployer,
    log: true,
    skipIfAlreadyDeployed: false,
    args,
  });
  await hre.run("verify:verify", { address: instance.address, constructorArguments: args });
};

module.exports = func;
func.tags = ["ArbitrumCustomGasTokenAdapter", "mainnet"];
