import { task } from "hardhat/config";
import type { HardhatRuntimeEnvironment } from "hardhat/types";
import "hardhat-deploy";
import "@nomiclabs/hardhat-ethers";

/**
 * Verify that the deployment init code (creation bytecode + encoded constructor args)
 * matches the locally reconstructed init code from artifacts and recorded args.
 *
 * Compares keccak256(initCodeOnChain) vs keccak256(initCodeLocal).
 *
 * Sample usage:
 *   yarn hardhat verify-bytecode --contract Arbitrum_Adapter --network mainnet
 *   yarn hardhat verify-bytecode --contract Arbitrum_Adapter --tx-hash 0x... --network mainnet
 *   yarn hardhat verify-bytecode --contract X --tx-hash 0x... --libraries "MyLib=0x...,OtherLib=0x..." --network mainnet
 */
task("verify-bytecode", "Verify deploy transaction input against local artifacts")
  .addOptionalParam("contract", "Contract name; falls back to env CONTRACT")
  // @dev For proxies, we don't save transactionHash in deployments/. You have to provide it manually via --tx-hash 0x... by checking e.g. block explorer first
  .addOptionalParam("txHash", "Deployment transaction hash (defaults to deployments JSON)")
  .addOptionalParam("libraries", "Libraries to link. JSON string or 'Name=0x..,Other=0x..'")
  .setAction(
    async (args: { contract?: string; txHash?: string; libraries?: string }, hre: HardhatRuntimeEnvironment) => {
      const { deployments, ethers, artifacts, network } = hre;

      // make sure we're using latest local contract artifacts for verification
      await hre.run("compile");

      const contractName = args.contract || process.env.CONTRACT;
      if (!contractName) throw new Error("Please provide --contract or set CONTRACT env var");

      const deployment = await deployments.get(contractName);
      const deployedAddress: string = deployment.address;
      const constructorArgs: any[] = deployment.args || [];

      const parseLibraries = (s?: string): Record<string, string> => {
        if (!s) return {};
        const out: Record<string, string> = {};
        const trimmed = s.trim();
        if (trimmed.startsWith("{") && trimmed.endsWith("}")) {
          const parsed = JSON.parse(trimmed);
          for (const [k, v] of Object.entries(parsed)) out[k] = String(v);
          return out;
        }
        for (const part of trimmed.split(/[\,\n]/)) {
          const [k, v] = part.split("=").map((x) => x.trim());
          if (k && v) out[k] = v;
        }
        return out;
      };

      // Read local compilation artifact
      const artifact = await artifacts.readArtifact(contractName);
      console.log("Reading compilation artifact for", artifact.sourceName);

      /**
       * TODO
       * the `libraries` bit is untested. Could be wrong. Could remove this part if we don't have contracts with dynamic libraries
       * artifact.linkReferences might help solve this better. Also, deployments.libraries. Implement only if required later.
       */
      const libraries: Record<string, string> = parseLibraries(args.libraries);
      const factory = await ethers.getContractFactoryFromArtifact(
        artifact,
        Object.keys(libraries).length ? { libraries } : {}
      );

      // Note: `factory.getDeployTransaction` populates the transaction with whatever data we WOULD put in it if we were deploying it right now
      const populatedDeployTransaction = factory.getDeployTransaction(...constructorArgs);
      const expectedInit: string = ethers.utils.hexlify(populatedDeployTransaction.data!).toLowerCase();
      if (!expectedInit || expectedInit === "0x") {
        throw new Error("Failed to reconstruct deployment init code from local artifacts");
      }

      // Get on-chain creation input
      const txHash = args.txHash ?? deployment.transactionHash;
      if (!txHash) {
        throw new Error("Could not find deployment tx hash. Pass --tx-hash when running script.");
      }
      const tx = await ethers.provider.getTransaction(txHash);
      if (!tx) throw new Error(`Transaction not found for hash ${txHash}`);
      if (tx.to && tx.to != "") {
        throw new Error(`Transaction ${txHash} is not a direct contract creation (tx.to=${tx.to})`);
      }

      const expectedHash = ethers.utils.keccak256(expectedInit);
      const onchainHash = ethers.utils.keccak256(tx.data.toLowerCase());

      console.log("\n=============== Deploy Tx Verification ===============");
      console.log(`Contract            : ${contractName}`);
      console.log(`Network             : ${network.name}`);
      console.log(`Deployed address    : ${deployedAddress}`);
      if (txHash) console.log(`Tx hash             : ${txHash}`);
      console.log("-------------------------------------------------------");
      console.log(`On-chain init hash  : ${onchainHash}`);
      console.log(`Local init hash     : ${expectedHash}`);
      console.log("-------------------------------------------------------");
      console.log(onchainHash === expectedHash ? "✅  MATCH" : "❌  MISMATCH – init code differs");
      console.log("=======================================================\n");
    }
  );
