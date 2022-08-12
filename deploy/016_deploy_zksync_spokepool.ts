import { HardhatRuntimeEnvironment } from "hardhat/types/runtime";
import { Wallet } from "zksync-web3";
import { Deployer } from "@matterlabs/hardhat-zksync-deploy";

import { L2_ADDRESS_MAP } from "./consts";

const func = async function (hre: HardhatRuntimeEnvironment) {
  const { companionNetworks, getChainId } = hre;

  // zk.Wallet extends ethers.Wallet
  if (!process.env.MNEMONIC) {
    console.log("Missing MNEMONIC");
    return;
  }

  const wallet = Wallet.fromMnemonic(process.env.MNEMONIC);
  const deployer = new Deployer(hre, wallet);

  // Grab L1 addresses:
  const { deployments: l1Deployments } = companionNetworks.l1;
  const hubPool = await l1Deployments.get("HubPool");
  console.log(`Using l1 hub pool @ ${hubPool.address}`);

  const chainId = parseInt(await getChainId());

  const artifact = await deployer.loadArtifact("ZkSync_SpokePool");
  const args = [
    L2_ADDRESS_MAP[chainId].zkErc20Bridge,
    L2_ADDRESS_MAP[chainId].zkEthBridge,
    hubPool.address, // Set hub pool as cross domain admin since it delegatecalls the ZkSync_Adapter logic.
    hubPool.address,
    L2_ADDRESS_MAP[chainId].l2Weth, // l2Weth
    "0x0000000000000000000000000000000000000000", // timer
  ];
  const contract = await deployer.deploy(artifact, args);
  console.log(`${artifact.contractName} was deployed to ${contract.address}`);
  console.log("args" + contract.interface.encodeDeploy(args));
};
module.exports = func;
func.tags = ["ZkSyncSpokePool", "zksync"];
