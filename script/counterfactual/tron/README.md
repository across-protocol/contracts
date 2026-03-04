# Tron Deploy Scripts

Deploys counterfactual deposit contracts to Tron via TronWeb.

Foundry cannot broadcast transactions to Tron directly — Tron uses protobuf-encoded transactions with SHA-256 signing, while Foundry uses RLP + keccak256. Each deploy script is a TypeScript wrapper that validates typed args, ABI-encodes constructor args, and calls the shared `deploy.ts` deployer which handles the TronWeb deployment.

## Networks

| Network      | Chain ID     | `.env` variable       | Node URL                   |
| ------------ | ------------ | --------------------- | -------------------------- |
| Tron mainnet | `728126428`  | `NODE_URL_728126428`  | `https://api.trongrid.io`  |
| Nile testnet | `3448148188` | `NODE_URL_3448148188` | `https://nile.trongrid.io` |

## Prerequisites

1. Download the Tron solc binary (required for TronScan-verifiable bytecode):

   ```bash
   # macOS
   curl -L -o bin/solc-tron \
     https://github.com/tronprotocol/solidity/releases/download/tv_0.8.25/solc-macos
   chmod +x bin/solc-tron

   # Linux
   curl -L -o bin/solc-tron \
     https://github.com/tronprotocol/solidity/releases/download/tv_0.8.25/solc-static-linux
   chmod +x bin/solc-tron
   ```

2. Compile Tron-compatible artifacts (Solidity 0.8.25, using Tron's solc fork):

   ```bash
   FOUNDRY_PROFILE=tron forge build
   ```

   This outputs artifacts to `out-tron/`.

3. Set environment variables in `.env` (loaded automatically via dotenv):

   ```
   MNEMONIC="x x x ... x"
   NODE_URL_728126428=https://api.trongrid.io
   NODE_URL_3448148188=https://nile.trongrid.io
   ```

4. Optional: set `TRON_FEE_LIMIT` in `.env` (in sun, default: `1500000000` = 1500 TRX).

## Deploy Commands

Every script takes `chainId` as its first argument (`728126428` for mainnet, `3448148188` for Nile testnet). **All address arguments use Tron Base58Check format** (`T...`), not `0x`-prefixed EVM hex.

### CounterfactualDepositFactoryTron (no constructor args)

```bash
yarn tron-deploy-counterfactual-factory <chainId>
```

### CounterfactualDepositCCTP

```bash
yarn tron-deploy-counterfactual-deposit-cctp <chainId> <srcPeriphery> <sourceDomain>
# e.g. yarn tron-deploy-counterfactual-deposit-cctp 3448148188 TXYZabc123... 6
```

### CounterfactualDepositOFT

```bash
yarn tron-deploy-counterfactual-deposit-oft <chainId> <oftSrcPeriphery> <srcEid>
```

### CounterfactualDepositSpokePool

```bash
yarn tron-deploy-counterfactual-deposit-spokepool <chainId> <spokePool> <signer> <wrappedNativeToken>
```

### WithdrawImplementation (no constructor args)

```bash
yarn tron-deploy-withdraw-implementation <chainId>
```

### Deploy Clone (test address prediction)

Deploys a clone from the factory and verifies the predicted address matches the actual deployed address.

```bash
yarn tron-deploy-counterfactual-clone <chainId> <factory> <implementation> <paramsHash> <salt>
# Addresses are Tron Base58Check (T...), paramsHash and salt are 0x-prefixed 32-byte hex.
```

## File Overview

| File                                              | Purpose                                                                         |
| ------------------------------------------------- | ------------------------------------------------------------------------------- |
| `deploy.ts`                                       | Shared TronWeb deployer — reads Foundry artifacts, deploys via TronWeb          |
| `tron-deploy-counterfactual-factory.ts`           | Deploys `CounterfactualDepositFactoryTron` (no args)                            |
| `tron-deploy-counterfactual-deposit-cctp.ts`      | Deploys `CounterfactualDepositCCTP(srcPeriphery, sourceDomain)`                 |
| `tron-deploy-counterfactual-deposit-oft.ts`       | Deploys `CounterfactualDepositOFT(oftSrcPeriphery, srcEid)`                     |
| `tron-deploy-counterfactual-deposit-spokepool.ts` | Deploys `CounterfactualDepositSpokePool(spokePool, signer, wrappedNativeToken)` |
| `tron-deploy-withdraw-implementation.ts`          | Deploys `WithdrawImplementation` (no args)                                      |
| `tron-deploy-counterfactual-clone.ts`             | Deploys a clone from factory, verifies address prediction                       |

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

## TronScan Verification

TronScan uses Tron's own solc fork, so contracts must be compiled with it to produce matching bytecode. The `[profile.tron]` Foundry profile is configured to use `bin/solc-tron` for this (see [Prerequisites](#prerequisites) step 1).

To verify a contract on TronScan:

1. Flatten the contract source:

   ```bash
   FOUNDRY_PROFILE=tron forge flatten contracts/periphery/counterfactual/<ContractName>.sol \
     -o flattened/<ContractName>.sol
   ```

2. Go to the contract's page on [TronScan](https://tronscan.org/) (or [Nile TronScan](https://nile.tronscan.org/) for testnet) and click **Verify & Publish**.

3. Upload the flattened `.sol` file with these settings:
   - **Compiler version**: `tron_v0.8.25`
   - **Optimization**: `Yes`, `800` runs
   - **License**: `BUSL-1.1`

## Notes

- The contract **artifacts** are compiled with `FOUNDRY_PROFILE=tron` (using Tron's solc 0.8.25 fork for TronScan-verifiable bytecode) and read from `out-tron/` at deploy time.
- All scripts load `.env` automatically via dotenv — no need to run `source .env` first.
- `deploy.ts` can also be used directly for any contract: `npx ts-node deploy.ts <chainId> <artifactPath> [encodedArgs]`.
- On failure (rejected tx, timeout, on-chain revert), scripts exit non-zero.
