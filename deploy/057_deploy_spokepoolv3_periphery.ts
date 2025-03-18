import { DeployFunction } from "hardhat-deploy/types";
import { HardhatRuntimeEnvironment } from "hardhat/types";
import { getDeployedAddress } from "../src/DeploymentUtils";
import { CHAIN_IDs } from "../utils";
import { L1_ADDRESS_MAP, L2_ADDRESS_MAP, WETH, WMATIC } from "./consts";

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployer } = await hre.getNamedAccounts();
  const chainId = parseInt(await hre.getChainId());
  const wrappedNativeToken =
    chainId === CHAIN_IDs.POLYGON || chainId === CHAIN_IDs.POLYGON_AMOY ? WMATIC[chainId] : WETH[chainId];
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

  const deployment = await hre.deployments.deploy("SpokePoolV3Periphery", {
    contract: "SpokePoolV3Periphery",
    from: deployer,
    log: true,
    skipIfAlreadyDeployed: true,
    deterministicDeployment: "0x123456789abc", // Salt for the create2 call.
    args: constructorArguments,
  });
  const spokePoolPeriphery = await ethers.getContractFactory("SpokePoolV3Periphery");
  const peripheryContract = spokePoolPeriphery.attach(deployment.address);

  const txn = await peripheryContract.initialize(spokePool, wrappedNativeToken, exchange);
  console.log(`Initialized the contract at transaction hash ${txn.hash}`);
  await hre.run("verify:verify", { address: deployment.address, constructorArguments });
};
module.exports = func;
func.tags = ["SpokePoolPeriphery"];
