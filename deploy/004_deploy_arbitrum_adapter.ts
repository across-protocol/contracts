// l1Arbitrum Inbox and L1ERC20 Gateway taken from: https://developer.offchainlabs.com/docs/public_testnet

import { L1_ADDRESS_MAP } from "./consts";

const func = async function (hre: any) {
  const { deployments, getNamedAccounts, getChainId } = hre;
  const { deploy, get } = deployments;

  const { deployer } = await getNamedAccounts();

  const hubPoolAddress = (await get("HubPool")).address;

  const chainId = await getChainId();

  await deploy("Arbitrum_Adapter", {
    from: deployer,
    log: true,
    skipIfAlreadyDeployed: true,
    args: [hubPoolAddress, L1_ADDRESS_MAP[chainId].l1ArbitrumInbox, L1_ADDRESS_MAP[chainId].l1ERC20Gateway],
  });
};

module.exports = func;
func.dependencies = ["HubPool"];
func.tags = ["arbitrum-adapter"];
