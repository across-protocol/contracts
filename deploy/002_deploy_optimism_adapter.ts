// Cross Domain Messengers grabbed from
// https://github.com/ethereum-optimism/optimism/tree/develop/packages/contracts/deployments

import { L1_ADDRESS_MAP } from "./consts";

const func = async function (hre: any) {
  const { deployments, getNamedAccounts, getChainId } = hre;
  const { deploy, get } = deployments;

  const { deployer } = await getNamedAccounts();

  const hubPoolAddress = (await get("HubPool")).address;

  const chainId = await getChainId();

  await deploy("Optimism_Adapter", {
    from: deployer,
    log: true,
    skipIfAlreadyDeployed: true,
    args: [
      L1_ADDRESS_MAP[chainId].weth,
      hubPoolAddress,
      L1_ADDRESS_MAP[chainId].optimismCrossDomainMessenger,
      L1_ADDRESS_MAP[chainId].optimismStandardBridge,
    ],
  });
};

module.exports = func;
func.tags = ["optimism-adapter"];
