# TRON Deployments via Local JSON-RPC Proxy

Deploy contracts to TRON using standard `forge create` commands. A local proxy translates Foundry's eth\_\* JSON-RPC calls into TRON HTTP API transactions.

```
forge create --rpc-url http://127.0.0.1:8545 ...
    |
    | eth_* JSON-RPC
    v
proxy.ts (localhost:8545)
    |
    | TRON HTTP API
    v
TRON Node (TronGrid / Nile)
```

## Why a Proxy?

Foundry cannot deploy to TRON directly. Although TRON's TVM is EVM-compatible at the smart contract level, the two chains differ at the transaction layer:

- **Transaction encoding** — Ethereum uses RLP encoding; TRON uses Protocol Buffers (protobuf).
- **Transaction signing** — Ethereum signs a keccak256 hash of the RLP-encoded transaction; TRON signs a SHA-256 hash (the `txID`) of the protobuf-encoded transaction. Both use the same secp256k1 curve, so the same private key works on both chains.
- **Deploy API** — Ethereum embeds contract creation in the transaction's `data` field with `to = null`. TRON uses a dedicated `/wallet/deploycontract` HTTP endpoint that takes bytecode, constructor parameters, fee limits, and energy settings as structured fields.
- **Gas model** — Ethereum uses gas with a market-driven fee. TRON uses an energy/bandwidth resource model with a `fee_limit` cap (denominated in sun).

The proxy bridges this gap by accepting Foundry's standard JSON-RPC calls and translating them into TRON-native API calls. Foundry thinks it's talking to an Ethereum node, while the proxy handles protobuf transaction construction, SHA-256 signing, and TRON-specific receipt polling behind the scenes. This lets us use `forge create` unchanged — no custom Solidity deploy scripts or FFI wrappers needed.

## Prerequisites

- Node.js >= 22 and `npx ts-node` available (both already in this repo)
- Foundry with `FOUNDRY_PROFILE=tron forge build` working
- `.env` with `MNEMONIC` and `NODE_URL_<chainId>` set
- TRON deployer account funded with TRX for energy/bandwidth fees

## Quick Start

```bash
# 1. Build contracts with the tron profile
FOUNDRY_PROFILE=tron forge build

# 2. Start the proxy (in its own terminal)
source .env
npx ts-node script/tron/proxy.ts 3448148188  # Nile testnet

# 3. Deploy a contract (in another terminal)
source .env
FOUNDRY_PROFILE=tron forge create \
  --rpc-url http://127.0.0.1:8545 --mnemonic "$MNEMONIC" --legacy \
  contracts/periphery/counterfactual/WithdrawImplementation.sol:WithdrawImplementation
```

## Networks

| Network        | Chain ID     | NODE_URL env var      |
| -------------- | ------------ | --------------------- |
| TRON Mainnet   | `728126428`  | `NODE_URL_728126428`  |
| Nile Testnet   | `3448148188` | `NODE_URL_3448148188` |
| Shasta Testnet | `2494104990` | `NODE_URL_2494104990` |

Node URLs should point to a TronGrid (or compatible) endpoint, e.g.:

- Nile: `https://nile.trongrid.io/jsonrpc`
- Mainnet: `https://api.trongrid.io/jsonrpc`

The proxy accepts URLs with or without the `/jsonrpc` suffix and derives both the JSON-RPC and HTTP API base URLs automatically.

## Deploy Commands

All commands assume the proxy is running and `.env` is sourced.

### CounterfactualDepositFactoryTron (no constructor args)

```bash
FOUNDRY_PROFILE=tron forge create \
  --rpc-url http://127.0.0.1:8545 --mnemonic "$MNEMONIC" --legacy \
  contracts/periphery/counterfactual/CounterfactualDepositFactoryTron.sol:CounterfactualDepositFactoryTron
```

### CounterfactualDepositCCTP (address srcPeriphery, uint32 sourceDomain)

```bash
FOUNDRY_PROFILE=tron forge create \
  --rpc-url http://127.0.0.1:8545 --mnemonic "$MNEMONIC" --legacy \
  --constructor-args <srcPeriphery> <sourceDomain> \
  contracts/periphery/counterfactual/CounterfactualDepositCCTP.sol:CounterfactualDepositCCTP
```

### CounterfactualDepositOFT (address oftSrcPeriphery, uint32 srcEid)

```bash
FOUNDRY_PROFILE=tron forge create \
  --rpc-url http://127.0.0.1:8545 --mnemonic "$MNEMONIC" --legacy \
  --constructor-args <oftSrcPeriphery> <srcEid> \
  contracts/periphery/counterfactual/CounterfactualDepositOFT.sol:CounterfactualDepositOFT
```

### CounterfactualDepositSpokePool (address spokePool, address signer, address wrappedNativeToken)

```bash
FOUNDRY_PROFILE=tron forge create \
  --rpc-url http://127.0.0.1:8545 --mnemonic "$MNEMONIC" --legacy \
  --constructor-args <spokePool> <signer> <wrappedNativeToken> \
  contracts/periphery/counterfactual/CounterfactualDepositSpokePool.sol:CounterfactualDepositSpokePool
```

### WithdrawImplementation (no constructor args)

```bash
FOUNDRY_PROFILE=tron forge create \
  --rpc-url http://127.0.0.1:8545 --mnemonic "$MNEMONIC" --legacy \
  contracts/periphery/counterfactual/WithdrawImplementation.sol:WithdrawImplementation
```

## Deployment Artifacts

After each confirmed deployment, the proxy writes an artifact to `deployments/tron/<ContractName>.json`:

```json
{
  "contractName": "CounterfactualDepositFactoryTron",
  "address": "0x...",
  "tronAddress": "T...",
  "txHash": "0x...",
  "chainId": 3448148188,
  "blockNumber": 12345678,
  "deployer": "0x...",
  "constructorArgs": "0x...",
  "timestamp": "2026-02-25T12:00:00.000Z"
}
```

Contract names are detected by matching initcode prefixes against compiled artifacts in `out-tron/`.

## Environment Variables

| Variable             | Required | Description                                                        |
| -------------------- | -------- | ------------------------------------------------------------------ |
| `MNEMONIC`           | Yes      | BIP-39 mnemonic for the deployer account                           |
| `NODE_URL_<chainId>` | Yes      | TronGrid JSON-RPC URL (e.g. `https://nile.trongrid.io/jsonrpc`)    |
| `TRON_FEE_LIMIT`     | No       | Max fee in sun (default: `1500000000` = 1500 TRX)                  |
| `TRONGRID_API_KEY`   | No       | TronGrid API key for authenticated requests (required for mainnet) |
| `PROXY_PORT`         | No       | Local proxy port (default: `8545`)                                 |

## How It Works

1. `forge create --legacy` builds a legacy Ethereum transaction (RLP-encoded, type 0) and sends it via `eth_sendRawTransaction`.
2. The proxy RLP-decodes the transaction to extract the initcode (`data` field).
3. The initcode is submitted to TRON's `/wallet/deploycontract` HTTP API. TVM executes initcode identically to the EVM — the full initcode (creation bytecode + ABI-encoded constructor args) is passed as `bytecode`.
4. The proxy signs the TRON transaction using the same private key (TRON uses secp256k1, same as Ethereum; the `txID` is the SHA-256 hash to sign).
5. The signed transaction is broadcast via `/wallet/broadcasttransaction`.
6. Foundry polls `eth_getTransactionReceipt` — the proxy forwards to TRON's JSON-RPC or falls back to `/wallet/gettransactioninfobyid` and builds a synthetic Ethereum receipt.

## Limitations

- **Contract creation only** — The proxy only supports `eth_sendRawTransaction` for contract deployments (`to = null`). It does not support arbitrary contract calls. Use TronScan or tronweb for post-deployment interactions.
- **No contract verification** — Foundry's `--verify` flag won't work. Verify contracts manually on [TronScan](https://tronscan.org/) or [Nile TronScan](https://nile.tronscan.org/).
- **Single deployer** — The proxy derives one deployer key from the mnemonic. All deployments use this address.
- **Sequential deployments** — Use `forge create` (one tx per invocation), not `forge script --broadcast` which has batching and nonce management that the proxy doesn't support.
- **No EIP-1559** — Always use the `--legacy` flag. TRON does not support EIP-1559 gas pricing.
