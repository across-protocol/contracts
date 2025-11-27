import { task, types } from "hardhat/config";
import type { HardhatRuntimeEnvironment } from "hardhat/types";
import { ethers } from "ethers";
import deploymentsJson from "../deployments/deployments.json";

// Minimal SP1Helios ABI subset needed by this task.
const SP1_HELIOS_ABI = [
  {
    type: "function",
    name: "VKEY_UPDATER_ROLE",
    inputs: [],
    outputs: [{ name: "", type: "bytes32", internalType: "bytes32" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "hasRole",
    inputs: [
      { name: "role", type: "bytes32", internalType: "bytes32" },
      { name: "account", type: "address", internalType: "address" },
    ],
    outputs: [{ name: "", type: "bool", internalType: "bool" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "heliosProgramVkey",
    inputs: [],
    outputs: [{ name: "", type: "bytes32", internalType: "bytes32" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "updateHeliosProgramVkey",
    inputs: [
      {
        name: "newHeliosProgramVkey",
        type: "bytes32",
        internalType: "bytes32",
      },
    ],
    outputs: [],
    stateMutability: "nonpayable",
  },
] as const;

// Expected value for VKEY_UPDATER_ROLE to sanity check on-chain value.
const EXPECTED_VKEY_UPDATER_ROLE = "0x07ecc55c8d82c6f82ef86e34d1905e0f2873c085733fa96f8a6e0316b050d174";

type DeploymentsJson = Record<string, Record<string, { address: string; blockNumber: number }>>;

const DEPLOYMENTS = deploymentsJson as DeploymentsJson;

function parseChainList(rawChains: string): number[] {
  const cleaned = (rawChains || "").replace(/\s/g, "");
  if (!cleaned) {
    throw new Error("chains parameter is required and must be non-empty");
  }

  const chainIds = cleaned.split(",").map((item) => {
    const n = Number(item);
    if (!Number.isInteger(n) || n <= 0) {
      throw new Error(`Invalid chain id: ${item}`);
    }
    return n;
  });

  return Array.from(new Set(chainIds)).sort((a, b) => a - b);
}

function normalizeVkey(rawVkey: string): string {
  let vkey = rawVkey.trim().toLowerCase();
  if (!vkey.startsWith("0x")) {
    vkey = `0x${vkey}`;
  }
  if (vkey.length !== 66) {
    throw new Error(`newvkey must be a 32-byte hex string (bytes32). Got length=${vkey.length}, value=${rawVkey}`);
  }
  if (!/^0x[0-9a-f]{64}$/.test(vkey)) {
    throw new Error(`newvkey must be valid hex bytes32. Got: ${rawVkey}`);
  }
  return vkey;
}

function getNetworkConfigForChainId(hre: HardhatRuntimeEnvironment, chainId: number) {
  const entry = Object.entries(hre.config.networks).find(
    ([, config]) => (config as any)?.chainId === chainId && (config as any)?.url
  );
  if (!entry) {
    throw new Error(`No Hardhat network with chainId=${chainId} and an RPC url configured`);
  }
  const [name, config] = entry;
  return { name, url: (config as any).url as string };
}

task("updatevkey", "Generate HubPool admin calldata to update SP1Helios program vkeys via Universal_SpokePool")
  .addParam("newvkey", "New Helios program vkey (bytes32 hex string)", undefined, types.string)
  .addParam(
    "chains",
    "Comma-delimited list of chain IDs whose Universal_SpokePool Helios vkey should be updated (e.g. 56,999,9745)",
    undefined,
    types.string
  )
  .setAction(async (args, hre: HardhatRuntimeEnvironment) => {
    const { ethers: hreEthers, deployments, artifacts } = hre;
    const newVkey = normalizeVkey(args.newvkey);
    const chainIds = parseChainList(args.chains);

    const hubPoolDeployment = await deployments.get("HubPool");
    const hubPoolInterface = new hreEthers.utils.Interface(hubPoolDeployment.abi);

    const universalSpokeArtifact = await artifacts.readArtifact("Universal_SpokePool");
    const universalSpokeInterface = new hreEthers.utils.Interface(universalSpokeArtifact.abi);
    const heliosInterface = new hreEthers.utils.Interface(SP1_HELIOS_ABI);

    const calls: Array<{
      chainId: number;
      target: string;
      data: string;
      spokePool: string;
      helios: string;
    }> = [];

    console.log(`Preparing Helios vkey update calldata for chains: ${chainIds.join(", ")}`);
    console.log(`Using HubPool at ${hubPoolDeployment.address}\n`);

    for (const chainId of chainIds) {
      const chainKey = chainId.toString();
      const chainDeployments = DEPLOYMENTS[chainKey];
      if (!chainDeployments || !chainDeployments.SpokePool?.address) {
        console.warn(`Skipping chain ${chainId}: no SpokePool entry in deployments/deployments.json`);
        continue;
      }

      const spokePoolAddress = chainDeployments.SpokePool.address;

      let networkConfig;
      try {
        networkConfig = getNetworkConfigForChainId(hre, chainId);
      } catch (err) {
        console.warn(`Skipping chain ${chainId}: ${(err as Error).message}`);
        continue;
      }

      const provider = new ethers.providers.StaticJsonRpcProvider(networkConfig.url);

      const spokePool = new hreEthers.Contract(spokePoolAddress, universalSpokeInterface, provider);

      let heliosAddress: string;
      try {
        heliosAddress = await spokePool.helios();
      } catch (err) {
        console.warn(
          `Skipping chain ${chainId}: SpokePool at ${spokePoolAddress} does not expose helios() (is it a Universal_SpokePool?)`
        );
        continue;
      }

      if (!heliosAddress || heliosAddress === hreEthers.constants.AddressZero) {
        console.warn(`Skipping chain ${chainId}: SpokePool.helios() returned zero address`);
        continue;
      }

      const heliosFromDeployments = chainDeployments.Helios?.address;
      if (heliosFromDeployments && heliosFromDeployments.toLowerCase() !== heliosAddress.toLowerCase()) {
        console.warn(
          `Warning: Helios address mismatch on chain ${chainId}. deployments.json=${heliosFromDeployments}, on-chain=${heliosAddress}`
        );
      }

      const helios = new hreEthers.Contract(heliosAddress, heliosInterface, provider);

      let vkeyRoleOnChain: string;
      try {
        vkeyRoleOnChain = await helios.VKEY_UPDATER_ROLE();
      } catch (err) {
        console.warn(`Skipping chain ${chainId}: failed to read VKEY_UPDATER_ROLE from Helios at ${heliosAddress}`);
        continue;
      }

      if (vkeyRoleOnChain.toLowerCase() !== EXPECTED_VKEY_UPDATER_ROLE.toLowerCase()) {
        console.warn(
          `Warning: VKEY_UPDATER_ROLE on Helios (${vkeyRoleOnChain}) does not match expected constant on chain ${chainId}`
        );
      }

      const spokeHasRole = await helios.hasRole(vkeyRoleOnChain, spokePoolAddress);
      if (!spokeHasRole) {
        console.warn(
          `Skipping chain ${chainId}: SpokePool (${spokePoolAddress}) does not have VKEY_UPDATER_ROLE on Helios (${heliosAddress})`
        );
        continue;
      }

      const currentVkey: string = await helios.heliosProgramVkey();
      if (currentVkey.toLowerCase() === newVkey.toLowerCase()) {
        console.log(`Chain ${chainId}: Helios already has the requested vkey; no update calldata generated`);
        continue;
      }

      console.log(
        `Chain ${chainId}: building updateHeliosProgramVkey() call via SpokePool ${spokePoolAddress} -> Helios ${heliosAddress}`
      );

      const heliosUpdateCalldata = heliosInterface.encodeFunctionData("updateHeliosProgramVkey", [newVkey]);

      const message = hreEthers.utils.defaultAbiCoder.encode(
        ["address", "bytes"],
        [heliosAddress, heliosUpdateCalldata]
      );

      const spokePoolAdminCalldata = universalSpokeInterface.encodeFunctionData("executeExternalCall", [message]);

      const hubPoolCalldata = hubPoolInterface.encodeFunctionData("relaySpokePoolAdminFunction", [
        chainId,
        spokePoolAdminCalldata,
      ]);

      calls.push({
        chainId,
        target: hubPoolDeployment.address,
        data: hubPoolCalldata,
        spokePool: spokePoolAddress,
        helios: heliosAddress,
      });
    }

    console.log(`\nGenerated ${calls.length} HubPool admin call(s).`);
    if (calls.length === 0) {
      console.log("No calldata generated. Check warnings above for chains that were skipped.");
      return;
    }

    console.log("\nPer-chain summary:");
    for (const call of calls) {
      console.log(`  - chainId=${call.chainId}, spokePool=${call.spokePool}, helios=${call.helios}`);
    }

    console.log("\nCalldata payloads (each entry is a call to HubPool.relaySpokePoolAdminFunction):");
    console.log(
      JSON.stringify(
        calls.map(({ chainId, target, data }) => ({ chainId, target, data })),
        null,
        2
      )
    );
  });
