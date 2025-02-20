import { HardhatRuntimeEnvironment } from "hardhat/types";
import { getDeployedAddress } from "../src/DeploymentUtils";
import { CHAIN_IDs } from "../utils";
import { L1_ADDRESS_MAP, L2_ADDRESS_MAP, WETH, WMATIC } from "./consts";
import { Deployer as zkDeployer } from "@matterlabs/hardhat-zksync-deploy";
import { DeployFunction, DeploymentSubmission } from "hardhat-deploy/types";
import * as zk from "zksync-web3";

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const contractName = "SpokePoolV3Periphery";
  const chainId = parseInt(await hre.getChainId());
  const wrappedNativeToken = WETH[chainId];
  const spokePool = getDeployedAddress("SpokePool", chainId);
  const exchange =
    chainId === 1 ? L1_ADDRESS_MAP[chainId].uniswapV3SwapRouter02 : L2_ADDRESS_MAP[chainId].uniswapV3SwapRouter02;
  const constructorArguments = [
    // Allows function selectors in Uniswap V3 SwapRouter02:
    // - exactInputSingle
    // - exactInput
    // - exactOutputSingle
    // - exactOutput
    // - multicall
    // See https://etherscan.io/address/0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45#writeProxyContract
    ["0xb858183f", "0x04e45aaf", "0x09b81346", "0x5023b4df", "0x1f0464d1", "0x5ae401dc", "0xac9650d8"],
  ];

  const mnemonic = hre.network.config.accounts.mnemonic;
  const wallet = zk.Wallet.fromMnemonic(mnemonic);
  const deployer = new zkDeployer(hre, wallet);

  const artifact = await deployer.loadArtifact(contractName);
  const _deployment = await deployer.deploy(artifact, constructorArguments);
  const newAddress = _deployment.address;

  const extendedArtifact = await deployments.getExtendedArtifact(contractName);
  const deployment: DeploymentSubmission = {
    address: newAddress,
    ...extendedArtifact,
  };
  await deployments.save(contractName, deployment);

  const spokePoolPeriphery = await ethers.getContractFactory(contractName);
  const peripheryContract = spokePoolPeriphery.attach(deployment.address);

  const txn = await peripheryContract.initialize(spokePool, wrappedNativeToken, exchange);
  console.log(`Initialized the contract at transaction hash ${txn.hash}`);
  await hre.run("verify:verify", { address: deployment.address, constructorArguments });
};
module.exports = func;
func.tags = ["SpokePoolPeripheryZk"];
