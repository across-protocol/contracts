import { getMnemonic } from "@uma/common";
import { L1_ADDRESS_MAP, L2_ADDRESS_MAP, WETH } from "./consts";
import { CHAIN_IDs } from "../utils";
import { Contract } from "ethers";
import assert from "assert";
import * as zk from "zksync-web3";
import { Deployer as zkDeployer } from "@matterlabs/hardhat-zksync-deploy";
import { DeployFunction, DeploymentSubmission } from "hardhat-deploy/types";
import { HardhatRuntimeEnvironment } from "hardhat/types";
import contractDeployments from "../deployments/deployments.json";

/**
 * Usage:
 * $ yarn hardhat deploy --network mainnet --tags SpokePoolPeripheryZk
 */

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const contractName = "SpokePoolV3Periphery";
  const { deployer } = await hre.getNamedAccounts();
  const { network, deployments } = hre;
  const chainId = parseInt(await hre.getChainId());

  assert(chainId === CHAIN_IDs.ZK_SYNC);
  const spokePoolAddress = contractDeployments[chainId]?.SpokePool?.address;
  if (!spokePoolAddress) throw new Error(`SpokePool entry not found in deployments.json for chain ${chainId}`);

  const signer = zk.Wallet.fromMnemonic(getMnemonic());
  const deployer = new zkDeployer(hre, signer);

  const ethAmount = 0;
  const salt = "0x0000000000000000000000000000000000000000000000000000012345678910";

  // We know we are on ZkSync.
  const create2FactoryAddress = L2_ADDRESS_MAP[chainId].create2Factory;
  const permit2 = L2_ADDRESS_MAP[chainId].permit2;
  const peripheryProxy = L2_ADDRESS_MAP[chainId].spokePoolPeripheryProxy;

  const peripheryArtifact = await deployer.loadArtifact(contractName);
  const periphery = new Contract(create2FactoryAddress, peripheryArtifact.abi, deployer); // Address does not matter since we are just using the abi to encode function data.
  const initializationCode = await periphery.populateTransaction.initialize(
    spokePoolAddress,
    WETH[chainId],
    peripheryProxy,
    permit2
  );
  const _deployment = await deployer.deploy(peripheryArtifact, []);
  const peripheryAddress = _deployment.address;
  console.log(`New ${contractName} implementation deployed @ ${peripheryAddress}`);
  const extendedArtifact = await deployments.getExtendedArtifact(contractName);
  const deployment: DeploymentSubmission = {
    address: peripheryAddress,
    ...extendedArtifact,
  };
  await deployments.save(contractName, deployment);
  console.log(deployer);

  await hre.run("verify:verify", { address: peripheryAddress });
};

module.exports = func;
func.tags = ["SpokePoolPeripheryZk"];
