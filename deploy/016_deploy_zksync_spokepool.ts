import "hardhat-deploy";
import hre from "hardhat";
import { L2_ADDRESS_MAP } from "./consts";
import { getContractFactory } from "../utils";

const func = async function () {
  const { upgrades, companionNetworks, run, getChainId } = hre;

  // Grab L1 addresses:
  const { deployments: l1Deployments } = companionNetworks.l1;
  const hubPool = await l1Deployments.get("HubPool");
  console.log(`Using l1 hub pool @ ${hubPool.address}`);

  const chainId = parseInt(await getChainId());

  // Set hub pool as cross domain admin since it delegatecalls the Adapter logic.
  const constructorArgs = [
    0, // Start at 0 since this first time we're deploying this spoke pool. On future upgrades increase this.
    L2_ADDRESS_MAP[chainId].zkErc20Bridge,
    L2_ADDRESS_MAP[chainId].zkEthBridge,
    hubPool.address,
    hubPool.address,
    L2_ADDRESS_MAP[chainId].l2Weth,
  ];
  const spokePool = await upgrades.deployProxy(await getContractFactory("ZkSync_SpokePool"), constructorArgs, {
    kind: "uups",
  });
  const instance = await spokePool.deployed();
  console.log(`SpokePool deployed @ ${instance.address}`);
  const implementationAddress = await upgrades.erc1967.getImplementationAddress(instance.address);
  console.log(`Implementation deployed @ ${implementationAddress}`);

  // hardhat-upgrades overrides the `verify` task that ships with `hardhat` so that if the address passed
  // is a proxy, hardhat will first verify the implementation and then the proxy and also link the proxy
  // to the implementation's ABI on etherscan.
  // https://docs.openzeppelin.com/upgrades-plugins/1.x/api-hardhat-upgrades#verify
  await run("verify:verify", {
    address: instance.address,
  });
};
module.exports = func;
func.tags = ["ZkSyncSpokePool", "zksync"];
