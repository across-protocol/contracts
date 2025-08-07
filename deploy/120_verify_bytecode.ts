import { DeployFunction } from "hardhat-deploy/types";
import { HardhatRuntimeEnvironment } from "hardhat/types";
import { ethers } from "hardhat";
import fs from "fs";
import path from "path";

/**
 * Hardhat-deploy script that verifies that the bytecode of a live deployment matches the byte-code
 * produced by the current compilation artefacts in the repo.
 *
 * Usage example (Arbitrum_Adapter on mainnet):
 *    CONTRACT=Arbitrum_Adapter yarn hardhat deploy --network mainnet --tags verifyBytecode
 *
 * The script will:
 *  1. Read the compiled artefact for `CONTRACT` (artifacts/<source>/<Contract>.json) in the build
 *     folder and grab the creation byte-code and constructor ABI.
 *  2. Read the hardhat-deploy deployment file for the same network (`deployments/<network>/<CONTRACT>.json`)
 *     to obtain the constructor arguments that were used for the actual deployment together with the
 *     deployed address.
 *  3. Encode the constructor arguments with the ABI and append them to the creation byte-code – this
 *     is identical to the calldata used when the contract was created on-chain.
 *  4. Simulate a CREATE call (eth_call) with this creation code to obtain the runtime byte-code that
 *     would be stored on-chain.
 *  5. Fetch the real runtime byte-code from the chain via `eth_getCode`.
 *  6. Keccak-hash both byte-codes and print a comparison so reviewers can quickly see whether they
 *     match.
 */
const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const contractName = process.env.CONTRACT;
  if (contractName === undefined) {
    throw new Error("Please provide CONTRACT env var, e.g. Arbitrum_Adapter");
  }

  // ---------------------------------------------------------------------------
  // 1. Read compiled artefact (creation bytecode & constructor ABI)
  // ---------------------------------------------------------------------------
  const artifact = await hre.artifacts.readArtifact(contractName);
  const creationBytecode: string = artifact.bytecode; // hex-string starting with 0x
  const constructorFragment = artifact.abi.find((e: any) => e.type === "constructor");
  const constructorInputs = constructorFragment?.inputs || [];

  // ---------------------------------------------------------------------------
  // 2. Read deployment JSON for the current network (constructor args & address)
  // ---------------------------------------------------------------------------
  const networkName = hre.network.name;
  const deploymentInfo = await hre.deployments.get(contractName);
  const deployedAddress: string = deploymentInfo.address;
  const constructorArgs: any[] = deploymentInfo.args || [];

  // ---------------------------------------------------------------------------
  // 3. Encode constructor args and build full creation bytecode
  // ---------------------------------------------------------------------------
  const argTypes = constructorInputs.map((c: any) => c.type);
  const encodedArgs =
    argTypes.length > 0 ? ethers.utils.defaultAbiCoder.encode(argTypes, constructorArgs).slice(2) : "";
  const creationCodeWithArgs = creationBytecode + encodedArgs; // strip 0x from encodedArgs already

  // ---------------------------------------------------------------------------
  // 4. Simulate CREATE to obtain runtime bytecode (set generous gas limit)
  // ---------------------------------------------------------------------------
  const gasLimitEnv = process.env.GAS_LIMIT || "5000000"; // default 5M
  const gasLimit = ethers.BigNumber.from(gasLimitEnv);
  const runtimeBytecodeSim = await hre.ethers.provider.call({ data: creationCodeWithArgs, gasLimit });
  const runtimeBytecodeSimHash = ethers.utils.keccak256(runtimeBytecodeSim);

  // ---------------------------------------------------------------------------
  // 5. Fetch on–chain runtime bytecode for deployed address
  // ---------------------------------------------------------------------------
  const onchainRuntimeBytecode = await hre.ethers.provider.getCode(deployedAddress);
  const onchainRuntimeBytecodeHash = ethers.utils.keccak256(onchainRuntimeBytecode);

  // ---------------------------------------------------------------------------
  // 6. Print comparison for reviewers
  // ---------------------------------------------------------------------------
  console.log("\n================ Bytecode Verification ================");
  console.log(`Contract            : ${contractName}`);
  console.log(`Network             : ${networkName}`);
  console.log(`Deployed address    : ${deployedAddress}`);
  console.log("-------------------------------------------------------");
  console.log(`On-chain code hash  : ${onchainRuntimeBytecodeHash}`);
  console.log(`Simulated code hash : ${runtimeBytecodeSimHash}`);
  console.log("-------------------------------------------------------");
  console.log(
    onchainRuntimeBytecodeHash === runtimeBytecodeSimHash
      ? "✅  MATCH"
      : "❌  MISMATCH – deployment does not match current artefacts"
  );
  console.log("=======================================================\n");
};

module.exports = func;
func.tags = ["verifyBytecode"];
