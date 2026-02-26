/**
 * TRON JSON-RPC Proxy
 *
 * Translates Foundry's `forge create` JSON-RPC calls into TRON transactions.
 * Runs a local HTTP server that accepts standard eth_* methods and forwards
 * contract deployments to a TRON node via its HTTP API.
 *
 * Usage:
 *   source .env
 *   npx ts-node script/tron/proxy.ts <chain-id>
 *
 * Example:
 *   npx ts-node script/tron/proxy.ts 3448148188   # Nile testnet
 *   npx ts-node script/tron/proxy.ts 728126428     # Mainnet
 *
 * Then in another terminal:
 *   FOUNDRY_PROFILE=tron forge create \
 *     --rpc-url http://127.0.0.1:8545 --mnemonic "$MNEMONIC" --legacy \
 *     contracts/periphery/counterfactual/SomeContract.sol:SomeContract
 */

import http from "http";
import crypto from "crypto";
import fs from "fs";
import path from "path";
import { ethers } from "ethers";
import bs58 from "bs58";

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

const chainId = parseInt(process.argv[2], 10);
if (!chainId) {
  console.error("Usage: npx ts-node script/tron/proxy.ts <chain-id>");
  console.error("  e.g. npx ts-node script/tron/proxy.ts 3448148188  # Nile testnet");
  process.exit(1);
}

const mnemonic = process.env.MNEMONIC;
if (!mnemonic) {
  console.error("Error: MNEMONIC environment variable is required");
  process.exit(1);
}

const nodeUrl = process.env[`NODE_URL_${chainId}`];
if (!nodeUrl) {
  console.error(`Error: NODE_URL_${chainId} environment variable is required`);
  process.exit(1);
}

// Derive JSON-RPC and HTTP API URLs from the node URL.
// Accepts either "https://nile.trongrid.io/jsonrpc" or "https://nile.trongrid.io".
const tronRpcUrl = nodeUrl.endsWith("/jsonrpc") ? nodeUrl : nodeUrl + "/jsonrpc";
const tronApiBase = nodeUrl.replace(/\/jsonrpc\/?$/, "");

// Optional TronGrid API key for authenticated requests.
const tronApiKey = process.env.TRONGRID_API_KEY;

// Deployer wallet derived from mnemonic (same key for ETH and TRON — same secp256k1 curve).
const wallet = ethers.Wallet.fromMnemonic(mnemonic);
const deployerEthAddr = wallet.address.toLowerCase();
const deployerTronHex = "41" + deployerEthAddr.slice(2);
const signingKey = new ethers.utils.SigningKey(wallet.privateKey);

// Fee limit in sun. Default: 1500 TRX = 1,500,000,000 sun.
const feeLimit = parseInt(process.env.TRON_FEE_LIMIT || "1500000000", 10);

const PORT = parseInt(process.env.PROXY_PORT || "8545", 10);

// Project paths.
const ROOT = path.resolve(__dirname, "../..");
const ARTIFACTS_DIR = path.join(ROOT, "out-tron");
const DEPLOY_DIR = path.join(ROOT, "deployments", "tron");

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

let localNonce = 0;

// Tracks pending deployments so we can write artifacts when the receipt arrives.
const pendingDeploys = new Map<string, { initcode: string; contractName?: string; written: boolean }>();

// ---------------------------------------------------------------------------
// Address helpers
// ---------------------------------------------------------------------------

/** Encode a 21-byte TRON hex address (41-prefixed) to Base58Check. */
function toBase58Check(hexAddr: string): string {
  const bytes = Buffer.from(hexAddr, "hex");
  const h1 = crypto.createHash("sha256").update(bytes).digest();
  const h2 = crypto.createHash("sha256").update(h1).digest();
  return bs58.encode(new Uint8Array(Buffer.concat([bytes, h2.slice(0, 4)])));
}

/** Convert a 41-prefixed TRON hex address to an 0x-prefixed Ethereum address. */
function tronHexToEth(tronHex: string): string {
  return "0x" + tronHex.slice(2).toLowerCase();
}

// ---------------------------------------------------------------------------
// Artifact matching
// ---------------------------------------------------------------------------

interface Artifact {
  name: string;
  /** Hex creation bytecode without 0x prefix, lowercased. */
  bytecode: string;
}

/** Load compiled artifacts from out-tron/ for contract name detection. */
function loadArtifacts(): Artifact[] {
  const results: Artifact[] = [];
  if (!fs.existsSync(ARTIFACTS_DIR)) return results;

  for (const solFile of fs.readdirSync(ARTIFACTS_DIR)) {
    const solDir = path.join(ARTIFACTS_DIR, solFile);
    if (!fs.statSync(solDir).isDirectory()) continue;
    for (const jsonFile of fs.readdirSync(solDir)) {
      if (!jsonFile.endsWith(".json")) continue;
      try {
        const data = JSON.parse(fs.readFileSync(path.join(solDir, jsonFile), "utf-8"));
        const hex: string | undefined = data.bytecode?.object;
        if (hex && hex !== "0x") {
          results.push({ name: jsonFile.replace(".json", ""), bytecode: hex.replace(/^0x/, "").toLowerCase() });
        }
      } catch {
        /* skip unparseable artifacts */
      }
    }
  }

  // Sort longest bytecode first so we match the most specific contract.
  results.sort((a, b) => b.bytecode.length - a.bytecode.length);
  return results;
}

const artifacts = loadArtifacts();

/** Match initcode against known artifacts to determine the contract name. */
function matchArtifact(initcodeHex: string): Artifact | undefined {
  const lc = initcodeHex.toLowerCase();
  return artifacts.find((a) => lc.startsWith(a.bytecode));
}

// ---------------------------------------------------------------------------
// TRON network helpers
// ---------------------------------------------------------------------------

function tronHeaders(): Record<string, string> {
  const h: Record<string, string> = { "Content-Type": "application/json" };
  if (tronApiKey) h["TRON-PRO-API-KEY"] = tronApiKey;
  return h;
}

async function tronJsonRpc(method: string, params: any[]): Promise<any> {
  const resp = await fetch(tronRpcUrl, {
    method: "POST",
    headers: tronHeaders(),
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }),
  });
  const json: any = await resp.json();
  if (json.error) throw new Error(`TRON JSON-RPC error: ${JSON.stringify(json.error)}`);
  return json.result;
}

async function tronHttpApi(endpoint: string, body: any): Promise<any> {
  const resp = await fetch(`${tronApiBase}${endpoint}`, {
    method: "POST",
    headers: tronHeaders(),
    body: JSON.stringify(body),
  });
  return resp.json();
}

// ---------------------------------------------------------------------------
// eth_sendRawTransaction — the core deployment path
// ---------------------------------------------------------------------------

async function handleSendRawTransaction(rawTx: string): Promise<string> {
  // 1. RLP-decode the Ethereum transaction Foundry signed locally.
  const parsed = ethers.utils.parseTransaction(rawTx);
  if (parsed.to !== null && parsed.to !== undefined) {
    throw new Error("Only contract creation transactions are supported (to must be null)");
  }

  const initcodeHex = (parsed.data || "0x").replace(/^0x/, "");
  const artifact = matchArtifact(initcodeHex);
  const contractName = artifact?.name;
  console.log(`[deploy] Contract: ${contractName || "unknown"} | Initcode: ${initcodeHex.length / 2} bytes`);

  // 2. Build TRON deploy transaction — try full initcode as bytecode first.
  let tronTx: any = await tronHttpApi("/wallet/deploycontract", {
    owner_address: deployerTronHex,
    bytecode: initcodeHex,
    abi: "[]",
    parameter: "",
    fee_limit: feeLimit,
    call_value: 0,
    name: contractName || "Contract",
    consume_user_resource_percent: 100,
    origin_energy_limit: 10000000,
  });

  // Fallback: split creation bytecode from constructor args if TRON rejected combined initcode.
  if (tronTx.Error || tronTx.code) {
    console.log(`[deploy] Full initcode rejected (${tronTx.Error || tronTx.code}), trying split...`);
    if (!artifact)
      throw new Error(`Cannot split initcode — no matching artifact. Error: ${tronTx.Error || tronTx.code}`);

    const bytecode = initcodeHex.slice(0, artifact.bytecode.length);
    const constructorArgs = initcodeHex.slice(artifact.bytecode.length);
    tronTx = await tronHttpApi("/wallet/deploycontract", {
      owner_address: deployerTronHex,
      bytecode,
      abi: "[]",
      parameter: constructorArgs,
      fee_limit: feeLimit,
      call_value: 0,
      name: contractName || "Contract",
      consume_user_resource_percent: 100,
      origin_energy_limit: 10000000,
    });

    if (tronTx.Error || tronTx.code) {
      throw new Error(`TRON deploycontract failed: ${JSON.stringify(tronTx.Error || tronTx.code)}`);
    }
  }

  const txID: string = tronTx.txID;
  console.log(`[deploy] TRON txID: ${txID}`);

  // 3. Sign — TRON's txID is the SHA-256 digest to sign (same secp256k1 curve as Ethereum).
  const sig = signingKey.signDigest("0x" + txID);
  tronTx.signature = [ethers.utils.joinSignature(sig).slice(2)];

  // 4. Broadcast.
  const result = await tronHttpApi("/wallet/broadcasttransaction", tronTx);
  if (!result.result) throw new Error(`Broadcast failed: ${JSON.stringify(result)}`);
  console.log("[deploy] Broadcast OK");

  // 5. Track for artifact writing when receipt arrives.
  const txHash = "0x" + txID;
  pendingDeploys.set(txHash, { initcode: initcodeHex, contractName, written: false });
  localNonce++;

  return txHash;
}

// ---------------------------------------------------------------------------
// eth_getTransactionReceipt
// ---------------------------------------------------------------------------

async function handleGetTransactionReceipt(txHash: string): Promise<any> {
  const txId = txHash.replace(/^0x/, "");

  // Try TRON JSON-RPC first.
  try {
    const receipt = await tronJsonRpc("eth_getTransactionReceipt", [txHash]);
    if (receipt) {
      if (receipt.contractAddress) maybeWriteArtifact(txHash, receipt.contractAddress, receipt.blockNumber);
      return receipt;
    }
  } catch {
    /* fall through to HTTP API */
  }

  // Fallback: TRON HTTP API for transaction info.
  const info: any = await tronHttpApi("/wallet/gettransactioninfobyid", { value: txId });
  if (!info || !info.receipt || Object.keys(info).length === 0) return null; // Not confirmed yet.

  const contractAddr = info.contract_address ? tronHexToEth(info.contract_address) : null;
  const blockNum = info.blockNumber ? "0x" + info.blockNumber.toString(16) : "0x0";
  const status = info.receipt.result === "SUCCESS" ? "0x1" : "0x0";

  if (contractAddr) maybeWriteArtifact(txHash, contractAddr, blockNum);

  if (status !== "0x1") {
    const msg = info.resMessage ? Buffer.from(info.resMessage, "hex").toString("utf8") : "unknown";
    console.error(`[receipt] Transaction FAILED: ${msg}`);
  }

  return {
    transactionHash: txHash,
    transactionIndex: "0x0",
    blockHash: txHash,
    blockNumber: blockNum,
    from: deployerEthAddr,
    to: null,
    cumulativeGasUsed: "0x0",
    gasUsed: info.receipt.energy_usage_total ? "0x" + info.receipt.energy_usage_total.toString(16) : "0x0",
    contractAddress: contractAddr,
    logs: [],
    logsBloom: "0x" + "00".repeat(256),
    status,
    effectiveGasPrice: "0x1",
  };
}

// ---------------------------------------------------------------------------
// Deployment artifact writer
// ---------------------------------------------------------------------------

function maybeWriteArtifact(txHash: string, contractAddress: string, blockNumber: string | number): void {
  const entry = pendingDeploys.get(txHash);
  if (!entry || entry.written) return;
  entry.written = true;

  const name = entry.contractName || "Unknown";
  const tronHex = "41" + contractAddress.replace(/^0x/, "").toLowerCase();
  const tronAddr = toBase58Check(tronHex);
  const blockNum = typeof blockNumber === "string" ? parseInt(blockNumber, 16) : blockNumber;

  const artifact = matchArtifact(entry.initcode);
  const constructorArgs = artifact ? "0x" + entry.initcode.slice(artifact.bytecode.length) : "0x";

  const deploymentData = {
    contractName: name,
    address: contractAddress.toLowerCase(),
    tronAddress: tronAddr,
    txHash,
    chainId,
    blockNumber: blockNum,
    deployer: deployerEthAddr,
    constructorArgs,
    timestamp: new Date().toISOString(),
  };

  fs.mkdirSync(DEPLOY_DIR, { recursive: true });
  const filePath = path.join(DEPLOY_DIR, `${name}.json`);
  fs.writeFileSync(filePath, JSON.stringify(deploymentData, null, 2) + "\n");
  console.log(`[artifact] ${filePath}`);
  console.log(`[artifact] ${name} -> ${contractAddress} (${tronAddr})`);
}

// ---------------------------------------------------------------------------
// Main JSON-RPC dispatcher
// ---------------------------------------------------------------------------

async function handleRpc(method: string, params: any[]): Promise<any> {
  switch (method) {
    case "eth_chainId":
      return "0x" + chainId.toString(16);

    case "net_version":
      return chainId.toString();

    case "web3_clientVersion":
      return "TronProxy/1.0.0";

    case "eth_blockNumber":
      return tronJsonRpc(method, params);

    case "eth_getBlockByNumber": {
      const block = await tronJsonRpc(method, params);
      // TRON returns stateRoot: "0x" which crashes Foundry — patch to 32 zero bytes.
      if (block && (!block.stateRoot || block.stateRoot === "0x")) {
        block.stateRoot = "0x" + "00".repeat(32);
      }
      return block;
    }

    case "eth_getTransactionCount":
      return "0x" + localNonce.toString(16);

    case "eth_gasPrice":
    case "eth_maxPriorityFeePerGas":
      return "0x1";

    case "eth_estimateGas":
      return "0x1000000";

    case "eth_sendRawTransaction":
      return handleSendRawTransaction(params[0]);

    case "eth_getTransactionReceipt":
      return handleGetTransactionReceipt(params[0]);

    case "eth_getTransactionByHash":
    case "eth_getCode":
    case "eth_call":
    case "eth_getBalance":
      return tronJsonRpc(method, params);

    case "eth_accounts":
      return [deployerEthAddr];

    default:
      console.warn(`[warn] Unhandled: ${method}`);
      return null;
  }
}

// ---------------------------------------------------------------------------
// HTTP server
// ---------------------------------------------------------------------------

const server = http.createServer((req, res) => {
  let body = "";
  req.on("data", (chunk: string) => (body += chunk));
  req.on("end", async () => {
    try {
      const request = JSON.parse(body);

      // Batch JSON-RPC support.
      if (Array.isArray(request)) {
        const results = await Promise.all(
          request.map(async (r: any) => {
            try {
              return { jsonrpc: "2.0", id: r.id, result: await handleRpc(r.method, r.params || []) };
            } catch (err: any) {
              return { jsonrpc: "2.0", id: r.id, error: { code: -32603, message: err.message } };
            }
          })
        );
        res.writeHead(200, { "Content-Type": "application/json" });
        res.end(JSON.stringify(results));
        return;
      }

      const { id, method, params } = request;
      console.log(`[rpc] ${method}`);

      try {
        const result = await handleRpc(method, params || []);
        res.writeHead(200, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ jsonrpc: "2.0", id, result }));
      } catch (err: any) {
        console.error(`[error] ${method}: ${err.message}`);
        res.writeHead(200, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ jsonrpc: "2.0", id, error: { code: -32603, message: err.message } }));
      }
    } catch (err: any) {
      console.error(`[error] Invalid JSON: ${err.message}`);
      res.writeHead(400, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ jsonrpc: "2.0", id: null, error: { code: -32700, message: "Parse error" } }));
    }
  });
});

server.listen(PORT, "127.0.0.1", () => {
  console.log("");
  console.log("TRON JSON-RPC Proxy");
  console.log(`  Listening:  http://127.0.0.1:${PORT}`);
  console.log(`  Chain ID:   ${chainId}`);
  console.log(`  TRON Node:  ${tronRpcUrl}`);
  console.log(`  Deployer:   ${deployerEthAddr}`);
  console.log(`  TRON Addr:  ${toBase58Check(deployerTronHex)}`);
  console.log(`  Fee Limit:  ${feeLimit} sun (${feeLimit / 1_000_000} TRX)`);
  console.log(`  Artifacts:  ${ARTIFACTS_DIR}`);
  console.log("");
  console.log("Ready for forge create --rpc-url http://127.0.0.1:" + PORT + " ...");
  console.log("");
});
