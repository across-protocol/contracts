import * as zk from "zksync-web3";
import { Deployer as zkDeployer } from "@matterlabs/hardhat-zksync-deploy";
import { DeployFunction, DeploymentSubmission } from "hardhat-deploy/types";
import { HardhatRuntimeEnvironment } from "hardhat/types";
import { L1_ADDRESS_MAP, L2_ADDRESS_MAP } from "./consts";
import { CHAIN_IDs } from "@across-protocol/constants";

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const contractName = "SpokePoolPeriphery";
  const { deployments } = hre;
  const chainId = parseInt(await hre.getChainId());

  const mnemonic = hre.network.config.accounts.mnemonic;
  const wallet = zk.Wallet.fromMnemonic(mnemonic);
  const deployer = new zkDeployer(hre, wallet);

  const artifact = await deployer.loadArtifact(contractName);

  const isMainnet = [CHAIN_IDs.MAINNET, CHAIN_IDs.SEPOLIA].includes(chainId);
  const permit2Address = isMainnet ? L1_ADDRESS_MAP[chainId].permit2 : L2_ADDRESS_MAP[chainId].permit2;

  if (!permit2Address) {
    throw new Error(`Permit2 address not found for chain ${chainId}`);
  }

  const constructorArgs = [permit2Address];

  const _deployment = await deployer.deploy(artifact, constructorArgs);
  const newAddress = _deployment.address;
  console.log(`New ${contractName} deployed @ ${newAddress}`);

  // Save the deployment manually because OZ's hardhat-upgrades packages bypasses hardhat-deploy.
  // See also: https://stackoverflow.com/questions/74870472
  const extendedArtifact = await deployments.getExtendedArtifact(contractName);
  const deployment: DeploymentSubmission = {
    address: newAddress,
    ...extendedArtifact,
  };
  await deployments.save(contractName, deployment);

  await hre.run("verify:verify", {
    address: newAddress,
    contract: "contracts/SpokePoolPeriphery.sol:SpokePoolPeriphery",
    constructorArguments: constructorArgs,
  });
};

module.exports = func;
func.tags = ["SpokePoolPeripheryZk"];
