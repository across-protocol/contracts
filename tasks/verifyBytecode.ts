import { task } from "hardhat/config";
import type { HardhatRuntimeEnvironment } from "hardhat/types";
import "hardhat-deploy"; // augment hre with deployments
import "@nomiclabs/hardhat-ethers"; // augment hre with ethers

/**
 * Verify that the on-chain runtime bytecode for a deployed contract matches the
 * runtime bytecode produced by the current local artifacts + recorded constructor args.
 *
 * Usage examples:
 *   CONTRACT=Arbitrum_Adapter yarn hardhat verify-bytecode --network mainnet
 *   yarn hardhat verify-bytecode --contract Arbitrum_Adapter --network mainnet
 *   yarn hardhat verify-bytecode --contract Arbitrum_Adapter --address 0x... --network mainnet
 */
task("verify-bytecode", "Compare on-chain runtime bytecode with simulated runtime bytecode")
  .addOptionalParam("contract", "Contract name; falls back to env CONTRACT")
  .addOptionalParam("address", "Override deployed address to fetch code from")
  .addOptionalParam("gasLimit", "Gas limit to use for create simulation", "5000000")
  .setAction(
    async (args: { contract?: string; address?: string; gasLimit?: string }, hre: HardhatRuntimeEnvironment) => {
      const { deployments, artifacts, ethers, network } = hre;

      const contractName = args.contract || process.env.CONTRACT;
      if (!contractName) throw new Error("Please provide --contract or set CONTRACT env var");

      // 1) Read compiled artifact (creation bytecode & constructor ABI)
      const artifact = await artifacts.readArtifact(contractName);
      const creationBytecode: string = artifact.bytecode; // hex 0x...
      const constructorFragment = artifact.abi.find((f: any) => f.type === "constructor");
      const constructorInputs = constructorFragment?.inputs || [];

      // 2) Read deployment JSON for current network (constructor args & address)
      const deployment = await deployments.get(contractName);
      const deployedAddress: string = args.address || deployment.address;
      const constructorArgs: any[] = (deployment as any).args || [];

      // 3) Encode constructor args and build full creation bytecode
      const argTypes = constructorInputs.map((i: any) => i.type);
      const encodedArgs =
        argTypes.length > 0 ? ethers.utils.defaultAbiCoder.encode(argTypes, constructorArgs).slice(2) : "";
      const creationCodeWithArgs = creationBytecode + encodedArgs;

      // 4) Simulate CREATE to obtain runtime bytecode
      const gasLimit = ethers.BigNumber.from(args.gasLimit || "5000000");
      const runtimeBytecodeSim = await ethers.provider.call({ data: creationCodeWithArgs, gasLimit });
      const runtimeBytecodeSimHash = ethers.utils.keccak256(runtimeBytecodeSim);

      // 5) Fetch on-chain runtime bytecode for deployed address
      const onchainRuntimeBytecode = await ethers.provider.getCode(deployedAddress);
      const onchainRuntimeBytecodeHash = ethers.utils.keccak256(onchainRuntimeBytecode);

      // 6) Print comparison
      console.log("\n================ Bytecode Verification ================");
      console.log(`Contract            : ${contractName}`);
      console.log(`Network             : ${network.name}`);
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
    }
  );
