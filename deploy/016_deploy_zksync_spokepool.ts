import * as zk from "zksync-web3";
import { Deployer as zkDeployer } from "@matterlabs/hardhat-zksync-deploy";
import { DeployFunction } from "hardhat-deploy/types";
import { L2_ADDRESS_MAP } from "./consts";
import { HardhatRuntimeEnvironment } from "hardhat/types";

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const contractName = "ZkSync_SpokePool";
  const { getChainId, companionNetworks, zkUpgrades } = hre;

  const chainId = await getChainId();
  const hubPool = await companionNetworks.l1.deployments.get("HubPool");
  console.log(`Using HubPool @ ${hubPool.address}`);

  const mnemonic = hre.network.config.accounts.mnemonic;
  const wallet = zk.Wallet.fromMnemonic(mnemonic);
  const deployer = new zkDeployer(hre, wallet);

  const artifact = await deployer.loadArtifact(contractName);
  const initArgs = [
    0, // Start at 0 since this first time we're deploying this spoke pool. On future upgrades increase this.
    L2_ADDRESS_MAP[chainId].zkErc20Bridge,
    hubPool.address,
    hubPool.address,
    L2_ADDRESS_MAP[chainId].l2Weth,
  ];

  const proxy = await zkUpgrades.deployProxy(deployer.zkWallet, artifact, initArgs, {
    initializer: "initialize",
    kind: "uups",
    unsafeAllow: ["delegatecall"], // @dev Temporarily necessary, remove when possible.
  });
  console.log(`Deployment transaction hash: ${proxy.deployTransaction.hash}.`);
  await proxy.deployed();
  console.log(`${contractName} deployed to chain ID ${chainId} @ ${proxy.address}.`);

  const verificationId = await hre.run("verify:verify", {
    address: proxy.address,
  });
};

module.exports = func;
func.tags = ["ZkSyncSpokePool", "zksync"];
