import * as zk from "zksync-web3";
import { Deployer as zkDeployer } from "@matterlabs/hardhat-zksync-deploy";
import { DeployFunction, DeploymentSubmission } from "hardhat-deploy/types";
import { HardhatRuntimeEnvironment } from "hardhat/types";
import { getDeployedAddress } from "../src/DeploymentUtils";
import { L1_ADDRESS_MAP, L2_ADDRESS_MAP } from "./consts";
import { CHAIN_IDs } from "@across-protocol/constants";

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const contractName = "UniversalSwapAndBridge";
  const { deployments } = hre;

  const chainId = parseInt(await hre.getChainId());
  const mnemonic = hre.network.config.accounts.mnemonic;
  const wallet = zk.Wallet.fromMnemonic(mnemonic);
  const deployer = new zkDeployer(hre, wallet);

  const artifact = await deployer.loadArtifact(contractName);
  const constructorArgs = [
    getDeployedAddress("SpokePool", chainId),
    chainId === CHAIN_IDs.MAINNET ? L1_ADDRESS_MAP[chainId].lifiDiamond : L2_ADDRESS_MAP[chainId].lifiDiamond,
    // Allows swap function selectors in LiFi Diamond Proxy:
    // - swapTokensMultipleV3ERC20ToERC20 (0x5fd9ae2e)
    // - swapTokensMultipleV3ERC20ToNative (0x2c57e884)
    // - swapTokensMultipleV3NativeToERC20 (0x736eac0b)
    // - swapTokensSingleV3ERC20ToERC20 (0x4666fc80)
    // - swapTokensSingleV3ERC20ToNative (0x733214a3)
    // - swapTokensSingleV3NativeToERC20 (0xaf7060fd)
    // https://etherscan.io/address/0x1231DEB6f5749EF6cE6943a275A1D3E7486F4EaE#multipleProxyContract
    ["0x5fd9ae2e", "0x2c57e884", "0x736eac0b", "0x4666fc80", "0x733214a3", "0xaf7060fd"],
  ];

  const _deployment = await deployer.deploy(artifact, constructorArgs);
  const newAddress = _deployment.address;
  console.log(`New ${contractName} implementation deployed @ ${newAddress}`);

  // Save the deployment manually because OZ's hardhat-upgrades packages bypasses hardhat-deploy.
  // See also: https://stackoverflow.com/questions/74870472
  const extendedArtifact = await deployments.getExtendedArtifact(contractName);
  const deployment: DeploymentSubmission = {
    address: newAddress,
    ...extendedArtifact,
  };
  await deployments.save(contractName, deployment);

  await hre.run("verify:verify", { address: newAddress, constructorArguments: constructorArgs });
};

module.exports = func;
func.tags = ["LiFi_UniversalSwapAndBridgeZk", "UniversalSwapAndBridgeZk", "lifi"];
