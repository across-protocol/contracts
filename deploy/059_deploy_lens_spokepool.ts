import * as zk from "zksync-web3";
import { Deployer as zkDeployer } from "@matterlabs/hardhat-zksync-deploy";
import { HardhatRuntimeEnvironment } from "hardhat/types";
import { DeployFunction, DeploymentSubmission } from "hardhat-deploy/types";
import { getDeployedAddress } from "../src/DeploymentUtils";
import { getSpokePoolDeploymentInfo } from "../utils/utils.hre";
import { FILL_DEADLINE_BUFFER, L2_ADDRESS_MAP, QUOTE_TIME_BUFFER, USDC, WGHO, ZERO_ADDRESS } from "./consts";
import assert from "assert";

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const contractName = "Lens_SpokePool";
  const { deployments, zkUpgrades } = hre;

  const { hubPool, hubChainId, spokeChainId } = await getSpokePoolDeploymentInfo(hre);
  console.log(`Using chain ${hubChainId} HubPool @ ${hubPool.address}`);

  const mnemonic = hre.network.config.accounts.mnemonic;
  const wallet = zk.Wallet.fromMnemonic(mnemonic);
  const deployer = new zkDeployer(hre, wallet);

  const artifact = await deployer.loadArtifact(contractName);

  const { zkErc20Bridge, zkUSDCBridge, cctpTokenMessenger } = L2_ADDRESS_MAP[spokeChainId];

  const initArgs = [
    100_000, // Redeployment of the Spoke Pool proxy @ 09-01-2025. Offset the initial deposit ID by 100k
    zkErc20Bridge,
    hubPool.address,
    hubPool.address,
  ];

  const usdcAddress =
    zkUSDCBridge === ZERO_ADDRESS && cctpTokenMessenger === ZERO_ADDRESS ? ZERO_ADDRESS : USDC[spokeChainId];
  if (usdcAddress !== ZERO_ADDRESS) {
    const cctpTokenMessengerDefined = cctpTokenMessenger !== ZERO_ADDRESS;
    const zkUSDCBridgeDefined = zkUSDCBridge !== ZERO_ADDRESS;
    assert(
      cctpTokenMessengerDefined !== zkUSDCBridgeDefined,
      "Only one of zkUSDCBridge and cctpTokenMessenger should be set to a non-zero address"
    );
  }

  const constructorArgs = [
    WGHO[spokeChainId],
    usdcAddress,
    zkUSDCBridge,
    cctpTokenMessenger,
    QUOTE_TIME_BUFFER,
    FILL_DEADLINE_BUFFER,
  ];

  let newAddress: string;
  // On production, we'll rarely want to deploy a new proxy contract so we'll default to deploying a new implementation
  // contract.
  // If a SpokePool can be found in deployments/deployments.json, then only deploy an implementation contract.
  const proxy = getDeployedAddress("SpokePool", spokeChainId, false);
  const implementationOnly = proxy !== undefined;
  if (implementationOnly) {
    console.log(`${contractName} deployment already detected @ ${proxy}, deploying new implementation.`);
    const _deployment = await deployer.deploy(artifact, constructorArgs);
    newAddress = _deployment.address;
    console.log(`New ${contractName} implementation deployed @ ${newAddress}`);
  } else {
    const proxy = await zkUpgrades.deployProxy(deployer.zkWallet, artifact, initArgs, {
      initializer: "initialize",
      kind: "uups",
      constructorArgs,
      unsafeAllow: ["delegatecall"], // Remove after upgrading openzeppelin-contracts-upgradeable post v4.9.3.
    });
    console.log(`Deployment transaction hash: ${proxy.deployTransaction.hash}.`);
    await proxy.deployed();
    console.log(`${contractName} deployed to chain ID ${spokeChainId} @ ${proxy.address}.`);
    newAddress = proxy.address;
  }

  // Save the deployment manually because OZ's hardhat-upgrades packages bypasses hardhat-deploy.
  // See also: https://stackoverflow.com/questions/74870472
  const extendedArtifact = await deployments.getExtendedArtifact(contractName);
  const deployment: DeploymentSubmission = {
    address: newAddress,
    ...extendedArtifact,
  };
  await deployments.save(contractName, deployment);

  // Verify the proxy + implementation contract.
  await hre.run("verify:verify", { address: newAddress, constructorArguments: constructorArgs });
};

module.exports = func;
func.tags = ["LensSpokePool", "lens"];
