import { L1_ADDRESS_MAP } from "./consts";

const func = async function (hre: any) {
  const { deployments, getNamedAccounts, getChainId } = hre;
  const { deploy } = deployments;

  const { deployer } = await getNamedAccounts();

  const chainId = await getChainId();

  const adapter = await deployments.get("Optimism_Adapter");
  console.log(`Using l1 adapter @ ${adapter.address}`);
  const hubPool = await deployments.get("HubPool");
  console.log(`Using l1 hub pool @ ${hubPool.address}`);

  await deploy("Ethereum_SpokePool", {
    from: deployer,
    log: true,
    skipIfAlreadyDeployed: true,
    args: [
      adapter.address, // Set adapter as cross domain admin
      hubPool.address,
      L1_ADDRESS_MAP[chainId].weth,
      "0x0000000000000000000000000000000000000000",
    ],
  });
};
module.exports = func;
func.tags = ["ethereum-spokepool"];
