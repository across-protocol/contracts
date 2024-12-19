import assert from "assert";
import { HardhatRuntimeEnvironment } from "hardhat/types";
import { getMnemonic } from "@uma/common";
import { DeployFunction } from "hardhat-deploy/types";
import { L1_ADDRESS_MAP, L2_ADDRESS_MAP, WETH } from "./consts";
import { CHAIN_IDs } from "../utils";
import { Contract, ethers } from "ethers";
import deployments from "../deployments/deployments.json";

/**
 * Usage:
 * $ SPOKE_POOL_ADDRESS=0x.... yarn hardhat deploy --network mainnet --tags Create2Factory
 */

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployer } = await hre.getNamedAccounts();
  const { network } = hre;
  const chainId = parseInt(await hre.getChainId());
  const spokePoolAddress = deployments[chainId]?.SpokePool?.address;
  if (!spokePoolAddress) throw new Error(`SpokePool entry not found in deployments.json for chain ${chainId}`);
  const provider = new ethers.providers.StaticJsonRpcProvider(network.config.url);
  const signer = new ethers.Wallet.fromMnemonic(getMnemonic()).connect(provider);

  const ethAmount = 0;
  const salt = "0x0000000000000000000000000000000000000000000000000000012345678910";

  const onL1 = chainId === CHAIN_IDs.MAINNET || chainId === CHAIN_IDs.SEPOLIA;
  const create2FactoryAddress = onL1 ? L1_ADDRESS_MAP[chainId].create2Factory : L2_ADDRESS_MAP[chainId].create2Factory;
  const permit2 = onL1 ? L1_ADDRESS_MAP[chainId].permit2 : L2_ADDRESS_MAP[chainId].permit2;

  // TODO: Should we instead just pass this in as an argument?
  const peripheryProxy = onL1
    ? L1_ADDRESS_MAP[chainId].spokePoolPeripheryProxy
    : L2_ADDRESS_MAP[chainId].spokePoolPeripheryProxy;

  const factoryArtifact = await hre.artifacts.readArtifact("Create2Factory");
  const create2Factory = new Contract(create2FactoryAddress, factoryArtifact.abi, signer);

  const peripheryArtifact = await hre.artifacts.readArtifact("SpokePoolV3Periphery");
  const periphery = new Contract(create2FactoryAddress, peripheryArtifact.abi); // Address does not matter since we are just using the abi to encode function data.
  const initializationCode = await periphery.populateTransaction.initialize(
    spokePoolAddress,
    WETH[chainId],
    peripheryProxy,
    permit2
  );

  // Compute the expected create2 address so that we can verify it. If the address is not this address, then the deployment transaction will fail, since that implies that
  // an address was already deployed at this address.
  const expectedPeripheryAddress = ethers.utils.getCreate2Address(
    create2FactoryAddress,
    salt,
    ethers.utils.keccak256(peripheryArtifact.bytecode)
  );
  await (await create2Factory.deploy(ethAmount, salt, peripheryArtifact.bytecode, initializationCode.data)).wait();

  await hre.run("verify:verify", { address: expectedPeripheryAddress });
};

module.exports = func;
func.tags = ["SpokePoolPeriphery"];
