import { L2_ADDRESS_MAP } from "./consts";

const func = async function (hre: any) {
  const { deployments, getNamedAccounts, companionNetworks, getChainId } = hre;
  const { deploy } = deployments;

  const { deployer } = await getNamedAccounts();

  // Grab L1 addresses:
  const { deployments: l1Deployments } = companionNetworks.l1;
  const adapter = await l1Deployments.get("Arbitrum_Adapter");
  console.log(`Using l1 adapter @ ${adapter.address}`);
  const hubPool = await l1Deployments.get("HubPool");
  console.log(`Using l1 hub pool @ ${hubPool.address}`);

  const chainId = await getChainId();

  await deploy("Arbitrum_SpokePool", {
    from: deployer,
    log: true,
    skipIfAlreadyDeployed: true,
    args: [
      L2_ADDRESS_MAP[chainId].l2GatewayRouter, //_l2GatewayRouter
      adapter.address, // Set adapter as cross domain admin
      hubPool.address,
      L2_ADDRESS_MAP[chainId].l2Weth, // l2Weth
      "0x0000000000000000000000000000000000000000",
    ],
  });
};
module.exports = func;
func.tags = ["arbitrum-spokepool"];
