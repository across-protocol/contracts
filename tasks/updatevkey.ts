import { task, types } from "hardhat/config";
import type { HardhatRuntimeEnvironment } from "hardhat/types";
import { ethers } from "ethers";
import { getDeployedAddress } from "../src/DeploymentUtils";

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
    const hreAny = hre as any;
    const { ethers: hreEthers, deployments, artifacts } = hreAny;
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
    const failedChains: number[] = [];
    const chainsAlreadyUpToDate: number[] = [];

    console.log(`Preparing Helios vkey update calldata for chains: ${chainIds.join(", ")}`);
    console.log(`Using HubPool at ${hubPoolDeployment.address}\n`);

    for (const chainId of chainIds) {
      const spokePoolAddress = getDeployedAddress("SpokePool", chainId, false);
      if (!spokePoolAddress) {
        console.warn(`Skipping chain ${chainId}: no SpokePool entry in broadcast/deployed-addresses.json`);
        failedChains.push(chainId);
        continue;
      }

      let networkConfig;
      try {
        networkConfig = getNetworkConfigForChainId(hre, chainId);
      } catch (err) {
        console.warn(`Skipping chain ${chainId}: ${(err as Error).message}`);
        failedChains.push(chainId);
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
        failedChains.push(chainId);
        continue;
      }

      if (!heliosAddress || heliosAddress === hreEthers.constants.AddressZero) {
        console.warn(`Skipping chain ${chainId}: SpokePool.helios() returned zero address`);
        failedChains.push(chainId);
        continue;
      }

      const heliosFromDeployments = getDeployedAddress("Helios", chainId, false);
      if (heliosFromDeployments && heliosFromDeployments.toLowerCase() !== heliosAddress.toLowerCase()) {
        console.warn(
          `Warning: Helios address mismatch on chain ${chainId}. broadcast/deployed-addresses.json=${heliosFromDeployments}, on-chain=${heliosAddress}`
        );
      }

      const helios = new hreEthers.Contract(heliosAddress, heliosInterface, provider);

      let vkeyRoleOnChain: string;
      try {
        vkeyRoleOnChain = await helios.VKEY_UPDATER_ROLE();
      } catch (err) {
        console.warn(`Skipping chain ${chainId}: failed to read VKEY_UPDATER_ROLE from Helios at ${heliosAddress}`);
        failedChains.push(chainId);
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
        failedChains.push(chainId);
        continue;
      }

      const currentVkey: string = await helios.heliosProgramVkey();
      if (currentVkey.toLowerCase() === newVkey.toLowerCase()) {
        console.log(`Chain ${chainId}: Helios already has the requested vkey; no update calldata generated`);
        chainsAlreadyUpToDate.push(chainId);
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

    if (failedChains.length > 0) {
      console.error(
        `\nERROR: Failed to prepare vkey update calldata for the following chains: ${failedChains.join(", ")}`
      );
      throw new Error("One or more chains failed during vkey update preparation");
    }

    console.log(`\nGenerated ${calls.length} HubPool admin call(s).`);
    if (calls.length === 0) {
      console.log("All requested chains already have the provided Helios vkey; no HubPool calldata needed.");
      return;
    }

    console.log("\nPer-chain summary:");
    for (const call of calls) {
      console.log(`  - chainId=${call.chainId}, spokePool=${call.spokePool}, helios=${call.helios}`);
    }

    const targetChains = calls.map(({ chainId }) => chainId);
    const multicallData = calls.map(({ data }) => data);

    console.log(
      `\nData to use for HubPool.multicall on ${
        hubPoolDeployment.address
      }. Each entry is an encoded \`relaySpokePoolAdminFunction\` call. Included destination chains: [${targetChains.join(
        ", "
      )}]`
    );
    console.log(`\n[${multicallData.join(",")}]`);
  });
