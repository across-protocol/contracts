# Tron Deploy Scripts

Deploys counterfactual deposit contracts to Tron via Foundry FFI + TronWeb.

## Why FFI?

Foundry cannot broadcast transactions to Tron directly — Tron uses protobuf-encoded transactions with SHA-256 signing, while Foundry uses RLP + keccak256. Each Foundry script here is a typed wrapper that ABI-encodes constructor args, then FFI-calls `deploy.ts` which handles the actual TronWeb deployment.

```
Foundry script (type-safe args)
  → abi.encode(constructorArgs)
  → vm.ffi(["npx", "ts-node", "deploy.ts", chainId, artifactPath, encodedArgs])
      → deploy.ts resolves NODE_URL_<chainId> from env
      → reads artifact from out-tron/
      → TronWeb builds, signs, and broadcasts the transaction
      → polls for confirmation
      → returns ABI-encoded deployed address via stdout
  → abi.decode(result) → logs deployed address
```

## Networks

| Network      | Chain ID     | `.env` variable       | Node URL                   |
| ------------ | ------------ | --------------------- | -------------------------- |
| Tron mainnet | `728126428`  | `NODE_URL_728126428`  | `https://api.trongrid.io`  |
| Nile testnet | `3448148188` | `NODE_URL_3448148188` | `https://nile.trongrid.io` |

## Prerequisites

1. Compile Tron-compatible artifacts (Solidity 0.8.25):

   ```bash
   FOUNDRY_PROFILE=tron forge build
   ```

   This outputs artifacts to `out-tron/`.

2. Set environment variables (same `MNEMONIC` used by other deploy scripts):

   ```bash
   source .env  # needs MNEMONIC="x x x ... x" and NODE_URL_<chainId>="<node URL>"
   ```

3. Optional: set `TRON_FEE_LIMIT` in sun (default: `1500000000` = 1500 TRX).

## Deploy Commands

Every script takes `chainId` as its first argument (`728126428` for mainnet, `3448148188` for Nile testnet).

### CounterfactualDepositFactoryTron (no constructor args)

```bash
forge script script/counterfactual/tron/TronDeployCounterfactualDepositFactoryTron.s.sol \
  --sig "run(uint256)" 3448148188
```

### CounterfactualDepositCCTP

```bash
forge script script/counterfactual/tron/TronDeployCounterfactualDepositCCTP.s.sol \
  --sig "run(uint256,address,uint32)" <chainId> <srcPeriphery> <sourceDomain>
```

### CounterfactualDepositOFT

```bash
forge script script/counterfactual/tron/TronDeployCounterfactualDepositOFT.s.sol \
  --sig "run(uint256,address,uint32)" <chainId> <oftSrcPeriphery> <srcEid>
```

### CounterfactualDepositSpokePool

```bash
forge script script/counterfactual/tron/TronDeployCounterfactualDepositSpokePool.s.sol \
  --sig "run(uint256,address,address,address)" <chainId> <spokePool> <signer> <wrappedNativeToken>
```

### WithdrawImplementation (no constructor args)

```bash
forge script script/counterfactual/tron/TronDeployWithdrawImplementation.s.sol \
  --sig "run(uint256)" <chainId>
```

## File Overview

| File                                               | Purpose                                                                                                       |
| -------------------------------------------------- | ------------------------------------------------------------------------------------------------------------- |
| `deploy.ts`                                        | Shared TronWeb deployer — reads Foundry artifacts, deploys via TronWeb, returns ABI-encoded address to stdout |
| `TronDeployCounterfactualDepositFactoryTron.s.sol` | Deploys `CounterfactualDepositFactoryTron` (no args)                                                          |
| `TronDeployCounterfactualDepositCCTP.s.sol`        | Deploys `CounterfactualDepositCCTP(srcPeriphery, sourceDomain)`                                               |
| `TronDeployCounterfactualDepositOFT.s.sol`         | Deploys `CounterfactualDepositOFT(oftSrcPeriphery, srcEid)`                                                   |
| `TronDeployCounterfactualDepositSpokePool.s.sol`   | Deploys `CounterfactualDepositSpokePool(spokePool, signer, wrappedNativeToken)`                               |
| `TronDeployWithdrawImplementation.s.sol`           | Deploys `WithdrawImplementation` (no args)                                                                    |

## Deployment Artifacts

Each successful deployment writes two artifacts:

### 1. Foundry broadcast (`broadcast/`)

Written to `broadcast/TronDeploy<ContractName>.s.sol/<chainId>/run-<timestamp>.json` (plus a `run-latest.json` copy), matching the exact schema Foundry uses for `forge script --broadcast`. This means existing tooling that reads the `broadcast/` folder (e.g. `extract_foundry_addresses.sh`, deployment tracking) picks up TRON deployments automatically.

```
broadcast/
  TronDeployCounterfactualDepositFactoryTron.s.sol/
    3448148188/
      run-1771969799325.json
      run-latest.json
```

### 2. TRON deployment (`deployments/tron/`)

Written to `deployments/tron/<ContractName>.json` with TRON-specific fields (Base58Check address, node URL):

```json
{
  "contractName": "CounterfactualDepositFactoryTron",
  "address": "0x...",
  "tronAddress": "T...",
  "transactionHash": "abc123...",
  "constructorArgs": "0x...",
  "abi": [...],
  "deployedAt": "2026-02-25T12:00:00.000Z",
  "network": "https://nile.trongrid.io",
  "solcVersion": "0.8.25"
}
```

Re-deploying the same contract overwrites this artifact (broadcast artifacts are never overwritten — each run gets a new timestamped file).

## Notes

- The deploy scripts compile under the **default Foundry profile** (0.8.30). They don't import any counterfactual contracts — only `forge-std`.
- The contract **artifacts** are compiled separately with `FOUNDRY_PROFILE=tron` (0.8.25, the max Tron supports) and read from `out-tron/` at deploy time.
- `deploy.ts` writes human-readable logs to stderr (visible in the console) and the ABI-encoded address to stdout (consumed by Foundry's `vm.ffi`).
- On failure (rejected tx, timeout, on-chain revert), `deploy.ts` exits non-zero, which causes Foundry's `vm.ffi` to revert the script.
