import { task } from "hardhat/config";
import type { HardhatRuntimeEnvironment } from "hardhat/types";
import "hardhat-deploy";
import "@nomiclabs/hardhat-ethers";
import fs from "fs";
import path from "path";
import { execSync } from "child_process";

type VerifyBytecodeArgs = {
  contract?: string;
  txHash?: string;
  libraries?: string;
  broadcast?: string;
};

/**
 * Best-effort parser for `foundry.toml` that extracts the default profile's `out` directory.
 * Falls back to `<repo>/out` if anything goes wrong.
 */
function getFoundryOutDir(): string {
  const root = process.cwd();
  const configPath = path.join(root, "foundry.toml");

  if (!fs.existsSync(configPath)) {
    return path.join(root, "out");
  }

  const contents = fs.readFileSync(configPath, "utf8");
  const lines = contents.split(/\r?\n/);

  let inDefaultProfile = false;
  for (const rawLine of lines) {
    const line = rawLine.trim();

    if (line.startsWith("[") && line.endsWith("]")) {
      // Enter or exit `[profile.default]` section.
      inDefaultProfile = line === "[profile.default]";
      continue;
    }

    if (!inDefaultProfile) continue;

    const match = line.match(/^out\s*=\s*"(.*)"\s*$/);
    if (match) {
      const configuredOut = match[1].trim();
      if (configuredOut.length > 0) {
        return path.isAbsolute(configuredOut) ? configuredOut : path.join(root, configuredOut);
      }
    }
  }

  // Default Foundry output directory.
  return path.join(root, "out");
}

function normalizeFoundryBytecode(raw: any, key: "bytecode" | "deployedBytecode"): [string, any] {
  const value = raw[key];
  if (!value) {
    return ["0x", {}];
  }

  if (typeof value === "string") {
    const linksKey = key === "bytecode" ? "linkReferences" : "deployedLinkReferences";
    const links = raw[linksKey] ?? {};
    return [value, links];
  }

  if (typeof value === "object") {
    return [value.object ?? "0x", value.linkReferences ?? {}];
  }

  return ["0x", {}];
}

/**
 * Load a Foundry artifact (`out/...json`) and adapt it into a Hardhat-style artifact
 * that can be consumed by `ethers.getContractFactoryFromArtifact`.
 */
function loadFoundryArtifact(contractName: string): any {
  const outDir = getFoundryOutDir();
  const candidates = [
    path.join(outDir, `${contractName}.sol`, `${contractName}.json`),
    path.join(outDir, `${contractName}.json`),
  ];

  const artifactPath = candidates.find((p) => fs.existsSync(p));
  if (!artifactPath) {
    throw new Error(
      `Could not find Foundry artifact for contract "${contractName}". Tried:\n` +
        candidates.map((p) => `  - ${p}`).join("\n")
    );
  }

  const rawJson = fs.readFileSync(artifactPath, "utf8");
  const raw: any = JSON.parse(rawJson);

  const abi = raw.abi ?? [];
  const [bytecode, linkReferences] = normalizeFoundryBytecode(raw, "bytecode");
  const [deployedBytecode, deployedLinkReferences] = normalizeFoundryBytecode(raw, "deployedBytecode");

  return {
    _format: "hh-foundry-compat-0",
    contractName,
    sourceName: raw.sourceName ?? raw.source_name ?? path.basename(artifactPath),
    abi,
    bytecode,
    deployedBytecode,
    linkReferences,
    deployedLinkReferences,
  };
}

function ensureForgeBuildArtifacts() {
  try {
    // This keeps Foundry's `out/` artifacts up to date when verifying Foundry deployments.
    console.log("Running `forge build` to refresh Foundry artifacts...");
    execSync("forge build", { stdio: "inherit" });
  } catch (error: any) {
    throw new Error(`forge build failed: ${error?.message ?? String(error)}`);
  }
}

/**
Verify that the deployment init code (creation bytecode + encoded constructor args)
matches the locally reconstructed init code from artifacts and recorded args.

Compares keccak256(initCodeOnChain) vs keccak256(initCodeLocal).

Sample usage:
yarn hardhat verify-bytecode --contract Arbitrum_Adapter --network mainnet
yarn hardhat verify-bytecode --contract Arbitrum_Adapter --tx-hash 0x... --network mainnet
yarn hardhat verify-bytecode --contract X --tx-hash 0x... --libraries "MyLib=0x...,OtherLib=0x..." --network mainnet

For Foundry deployments that used `forge script --broadcast`, you can instead
point this task at the Foundry broadcast JSON:

yarn hardhat verify-bytecode \
  --contract DstOFTHandler \
  --broadcast broadcast/DeployDstHandler.s.sol/999/run-latest.json \
  --network hyperevm
 */
task("verify-bytecode", "Verify deploy transaction input against local artifacts")
  .addOptionalParam("contract", "Contract name; falls back to env CONTRACT")
  // @dev For proxies, we don't save transactionHash in deployments/. You have to provide it manually via --tx-hash 0x... by checking e.g. block explorer first
  .addOptionalParam("txHash", "Deployment transaction hash (defaults to deployments JSON)")
  .addOptionalParam("libraries", "Libraries to link. JSON string or 'Name=0x..,Other=0x..'")
  .addOptionalParam(
    "broadcast",
    "Path to Foundry broadcast JSON (e.g. broadcast/DeployFoo.s.sol/1/run-latest.json). " +
      "If set, constructor args and default txHash are taken from this file instead of hardhat-deploy deployments."
  )
  .setAction(async (args: VerifyBytecodeArgs, hre: HardhatRuntimeEnvironment) => {
    const { deployments, ethers, artifacts, network } = hre;

    const useFoundryArtifacts = Boolean(args.broadcast);

    // For Hardhat deployments, make sure we're using latest local Hardhat artifacts.
    if (!useFoundryArtifacts) {
      await hre.run("compile");
    } else {
      // For Foundry deployments, refresh Foundry's `out/` artifacts instead.
      ensureForgeBuildArtifacts();
    }

    const contractName = args.contract || process.env.CONTRACT;
    if (!contractName) throw new Error("Please provide --contract or set CONTRACT env var");

    /**
     * Resolve constructor args, deployed address and default tx hash either from:
     * - hardhat-deploy deployments (default), or
     * - Foundry broadcast JSON (when --broadcast is provided).
     */
    let deployedAddress: string | undefined;
    let constructorArgs: any[] = [];
    let defaultTxHash: string | undefined;

    if (args.broadcast) {
      const resolvedPath = path.isAbsolute(args.broadcast) ? args.broadcast : path.join(process.cwd(), args.broadcast);

      if (!fs.existsSync(resolvedPath)) {
        throw new Error(`Broadcast file not found at path ${resolvedPath}`);
      }

      // Narrow JSON structure to only what we need.
      type BroadcastTx = {
        hash?: string;
        transactionType?: string;
        contractName?: string;
        contractAddress?: string;
        arguments?: any[];
        transaction?: {
          input?: string;
        };
      };
      type BroadcastJson = {
        transactions?: BroadcastTx[];
      };

      const raw = fs.readFileSync(resolvedPath, "utf8");
      const parsed: BroadcastJson = JSON.parse(raw);
      const txs = parsed.transactions || [];

      const createTxsForContract = txs.filter(
        (tx) => tx.transactionType === "CREATE" && tx.contractName === contractName
      );

      if (!createTxsForContract.length) {
        throw new Error(`No CREATE transaction for contract "${contractName}" found in broadcast file ${resolvedPath}`);
      }

      let selected: BroadcastTx;
      if (args.txHash) {
        const match = createTxsForContract.find(
          (tx) => tx.hash && tx.hash.toLowerCase() === args.txHash!.toLowerCase()
        );
        if (!match) {
          throw new Error(
            `No CREATE transaction with hash ${args.txHash} for contract "${contractName}" in ${resolvedPath}`
          );
        }
        selected = match;
      } else if (createTxsForContract.length === 1) {
        selected = createTxsForContract[0];
      } else {
        const hashes = createTxsForContract
          .map((tx) => tx.hash)
          .filter(Boolean)
          .join(", ");
        throw new Error(
          `Multiple CREATE transactions for contract "${contractName}" found in ${resolvedPath}. ` +
            `Please re-run with --tx-hash set to one of: ${hashes}`
        );
      }

      if (!selected.hash) {
        throw new Error(`Selected broadcast transaction for "${contractName}" is missing a tx hash`);
      }

      deployedAddress = selected.contractAddress;
      constructorArgs = selected.arguments || [];
      defaultTxHash = selected.hash;
    } else {
      const deployment = await deployments.get(contractName);
      deployedAddress = deployment.address;
      constructorArgs = deployment.args || [];
      defaultTxHash = deployment.transactionHash;
    }

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

    // Read local compilation artifact (Hardhat or Foundry) for reconstructing init code.
    const artifact = useFoundryArtifacts
      ? loadFoundryArtifact(contractName)
      : await artifacts.readArtifact(contractName);
    console.log(
      "Reading compilation artifact for",
      (artifact as any).sourceName ?? (useFoundryArtifacts ? "<foundry>" : "<hardhat>")
    );

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
    const txHash = args.txHash ?? defaultTxHash;
    if (!txHash) {
      throw new Error(
        "Could not find deployment tx hash. Pass --tx-hash when running script, " +
          "or ensure deployments / broadcast metadata includes it."
      );
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
    if (deployedAddress) {
      console.log(`Deployed address    : ${deployedAddress}`);
    }
    if (args.broadcast) {
      console.log(`Broadcast file      : ${args.broadcast}`);
    }
    if (txHash) console.log(`Tx hash             : ${txHash}`);
    console.log("-------------------------------------------------------");
    console.log(`On-chain init hash  : ${onchainHash}`);
    console.log(`Local init hash     : ${expectedHash}`);
    console.log("-------------------------------------------------------");
    console.log(onchainHash === expectedHash ? "✅  MATCH" : "❌  MISMATCH – init code differs");
    console.log("=======================================================\n");
  });
