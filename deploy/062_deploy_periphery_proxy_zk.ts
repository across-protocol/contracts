import assert from "assert";
import * as zk from "zksync-web3";
import { Deployer as zkDeployer } from "@matterlabs/hardhat-zksync-deploy";
import { DeployFunction, DeploymentSubmission } from "hardhat-deploy/types";
import { HardhatRuntimeEnvironment } from "hardhat/types";
import { CHAIN_IDs } from "../utils";

/**
 * yarn hardhat deploy --network mainnet --tags SpokePoolPeripheryProxyZk
 */

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const contractName = "SpokePoolPeripheryProxy";
  const { deployments } = hre;
  const chainId = parseInt(await hre.getChainId());
  assert(chainId === CHAIN_IDs.ZK_SYNC);

  const mnemonic = hre.network.config.accounts.mnemonic;
  const wallet = zk.Wallet.fromMnemonic(mnemonic);
  const deployer = new zkDeployer(hre, wallet);

  const artifact = await deployer.loadArtifact(contractName);
  const constructorArgs = [];

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
func.tags = ["SpokePoolPeripheryProxyZk"];
