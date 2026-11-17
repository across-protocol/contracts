import * as fs from "fs";
import * as path from "path";
import { execSync } from "child_process";
import { BigNumber, ethers } from "ethers";
import { getAddress } from "ethers/lib/utils";

const DEFAULT_MULTISIG_NAME = "operations";

// The operations Safe keeps the original DeploySafe.s.sol folder so its committed artifacts and the `Safe`
// deployed-addresses key stay stable. Every other multisig gets its own DeploySafe_<Name>.s.sol folder, which
// ExtractDeployedFoundryAddresses.ts maps to a `Safe_<Name>` key.
export function getBroadcastScriptName(multisigName: string): string {
  if (multisigName === DEFAULT_MULTISIG_NAME) return "DeploySafe.s.sol";
  const pascal = multisigName
    .split("-")
    .map((part) => part.charAt(0).toUpperCase() + part.slice(1))
    .join("");
  return `DeploySafe_${pascal}.s.sol`;
}

function toHex(value: BigNumber | number | string | null | undefined): string | null {
  if (value === null || value === undefined) return null;
  return BigNumber.from(value).toHexString();
}

function getGitCommit(): string {
  try {
    return execSync("git rev-parse --short HEAD", { encoding: "utf8" }).trim();
  } catch {
    return "unknown";
  }
}

function serializeLog(log: ethers.providers.Log): Record<string, unknown> {
  return {
    address: getAddress(log.address),
    topics: log.topics,
    data: log.data,
    blockHash: log.blockHash,
    blockNumber: toHex(log.blockNumber),
    transactionHash: log.transactionHash,
    transactionIndex: toHex(log.transactionIndex),
    logIndex: toHex(log.logIndex),
    removed: log.removed,
  };
}

export function writeMultisigBroadcastArtifact(opts: {
  multisigName: string;
  chainId: number;
  contractAddress: string;
  deploymentTransaction: {
    data: string;
    to: string;
    value: string;
  };
  sentTransaction: ethers.providers.TransactionResponse;
  receipt: ethers.providers.TransactionReceipt;
  args: unknown[];
}): string {
  const timestamp = Math.floor(Date.now() / 1000);
  const tx = opts.sentTransaction;
  const receipt = opts.receipt;
  const broadcast = {
    transactions: [
      {
        hash: receipt.transactionHash,
        transactionType: "CREATE",
        contractName: "Safe",
        contractAddress: getAddress(opts.contractAddress),
        function: null,
        arguments: opts.args,
        transaction: {
          type: toHex(tx.type ?? 2),
          from: getAddress(tx.from),
          to: tx.to ? getAddress(tx.to) : getAddress(opts.deploymentTransaction.to),
          gas: toHex(tx.gasLimit),
          value: toHex(tx.value ?? opts.deploymentTransaction.value),
          input: tx.data ?? opts.deploymentTransaction.data,
          nonce: toHex(tx.nonce),
          accessList: tx.accessList ?? [],
        },
        additionalContracts: [],
        isFixedGasLimit: false,
      },
    ],
    receipts: [
      {
        transactionHash: receipt.transactionHash,
        transactionIndex: toHex(receipt.transactionIndex),
        blockHash: receipt.blockHash,
        blockNumber: toHex(receipt.blockNumber),
        from: getAddress(receipt.from),
        to: receipt.to ? getAddress(receipt.to) : null,
        cumulativeGasUsed: toHex(receipt.cumulativeGasUsed),
        gasUsed: toHex(receipt.gasUsed),
        contractAddress: getAddress(opts.contractAddress),
        logs: receipt.logs.map(serializeLog),
        status: toHex(receipt.status ?? 0),
        logsBloom: receipt.logsBloom,
        type: toHex(receipt.type ?? tx.type ?? 2),
        effectiveGasPrice: toHex(receipt.effectiveGasPrice),
      },
    ],
    libraries: [],
    pending: [],
    returns: {},
    timestamp,
    chain: opts.chainId,
    commit: getGitCommit(),
  };

  const broadcastDir = path.resolve(
    __dirname,
    "../../broadcast",
    getBroadcastScriptName(opts.multisigName),
    String(opts.chainId)
  );
  fs.mkdirSync(broadcastDir, { recursive: true });

  const serialized = JSON.stringify(broadcast, null, 2) + "\n";
  const runFile = path.join(broadcastDir, `run-${timestamp}.json`);
  const latestFile = path.join(broadcastDir, "run-latest.json");

  fs.writeFileSync(runFile, serialized);
  fs.writeFileSync(latestFile, serialized);

  return runFile;
}
