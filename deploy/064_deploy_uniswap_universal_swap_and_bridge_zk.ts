import * as zk from "zksync-web3";
import { Deployer as zkDeployer } from "@matterlabs/hardhat-zksync-deploy";
import { DeployFunction, DeploymentSubmission } from "hardhat-deploy/types";
import { HardhatRuntimeEnvironment } from "hardhat/types";
import { getDeployedAddress } from "../src/DeploymentUtils";
import { L1_ADDRESS_MAP, L2_ADDRESS_MAP } from "./consts";

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
    chainId === 1 ? L1_ADDRESS_MAP[chainId].uniswapV3SwapRouter02 : L2_ADDRESS_MAP[chainId].uniswapV3SwapRouter02,
    // Allows function selectors in Uniswap V3 SwapRouter02:
    // - exactInputSingle
    // - exactInput
    // - exactOutputSingle
    // - exactOutput
    // - multicall
    // See https://etherscan.io/address/0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45#writeProxyContract
    ["0xb858183f", "0x04e45aaf", "0x09b81346", "0x5023b4df", "0x1f0464d1", "0x5ae401dc", "0xac9650d8"],
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
func.tags = ["UniswapV3_UniversalSwapAndBridgeZk", "UniversalSwapAndBridgeZk", "uniswapV3"];
