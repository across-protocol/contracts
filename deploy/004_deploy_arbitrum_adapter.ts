// l1Arbitrum Inbox and L1ERC20 Gateway taken from: https://developer.offchainlabs.com/docs/public_testnet

import { L1_ADDRESS_MAP } from "./consts";

// This import is needed to override the definition of the HardhatRuntimeEnvironment type.
import "hardhat-deploy";
import { HardhatRuntimeEnvironment } from "hardhat/types/runtime";

const func = async function (hre: HardhatRuntimeEnvironment) {
  const { deployments, getNamedAccounts, getChainId } = hre;
  const { deploy } = deployments;

  const { deployer } = await getNamedAccounts();

  const chainId = parseInt(await getChainId());

  await deploy("Arbitrum_Adapter", {
    from: deployer,
    log: true,
    skipIfAlreadyDeployed: true,
    args: [L1_ADDRESS_MAP[chainId].l1ArbitrumInbox, L1_ADDRESS_MAP[chainId].l1ERC20Gateway],
  });
};

module.exports = func;
func.dependencies = ["HubPool"];
func.tags = ["ArbitrumAdapter", "mainnet"];
