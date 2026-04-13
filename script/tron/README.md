# Tron Deployment Scripts

TypeScript scripts for deploying contracts to Tron via TronWeb. Tron uses a protobuf transaction format (not RLP) and SHA-256 signing (not keccak256), so Foundry's `forge script --broadcast` cannot deploy directly — these scripts handle that.

## Prerequisites

### 1. Tron solc binary

Download Tron's custom solc 0.8.25 from [tronprotocol/solidity releases](https://github.com/tronprotocol/solidity/releases) and place it at `bin/solc-tron`:

```bash
mkdir -p bin

# macOS (Apple Silicon)
curl -L -o bin/solc-tron https://github.com/tronprotocol/solidity/releases/download/tv_0.8.25/solc-macos
chmod +x bin/solc-tron

# Linux (amd64)
curl -L -o bin/solc-tron https://github.com/tronprotocol/solidity/releases/download/tv_0.8.25/solc-static-linux
chmod +x bin/solc-tron
```

Verify:

```bash
bin/solc-tron --version
# solc.tron, the solidity compiler commandline interface
# Version: 0.8.25+commit.77bd169f...
```

### 2. Build contracts

```bash
yarn build-tron
```

This runs `FOUNDRY_PROFILE=tron forge build`, which compiles using Tron's solc (`bin/solc-tron`) and outputs Foundry artifacts to `out-tron/`.

### 3. Environment variables

Create a `.env` file (or `source .env` before running):

```bash
# Required for all deployments
MNEMONIC="your twelve word mnemonic phrase here"
NODE_URL_728126428=https://api.trongrid.io        # Tron mainnet
NODE_URL_3448148188=https://nile.trongrid.io       # Tron Nile testnet

# Optional
TRON_FEE_LIMIT=100000000  # Fee limit in sun (default: 100 TRX)
```

> **Important:** Use the base TronGrid URL (`https://api.trongrid.io`), NOT the `/jsonrpc` endpoint. TronWeb needs the native Tron API, not the Ethereum-compatible JSON-RPC endpoint.

## Flags

All scripts default to **Tron mainnet** (`728126428`). Pass `--testnet` to deploy to Nile testnet (`3448148188`). All address arguments use **Tron Base58Check format** (`T...`).

## Universal SpokePool Scripts

### SP1AutoVerifier

No-op verifier for testing SP1Helios without real ZK proofs. No constructor args.

```bash
yarn tron-deploy-sp1-auto-verifier [--testnet]
```

### SP1Helios

Ethereum beacon chain light client. Downloads a genesis binary to generate initial state, then deploys.

Additional env vars:

```bash
SP1_RELEASE_TRON=0.1.0-alpha.20                   # Genesis binary version
SP1_PROVER_MODE_TRON=network                       # "mock", "cpu", "cuda", or "network"
SP1_VERIFIER_ADDRESS_TRON=T...                     # SP1 verifier gateway (Base58Check)
SP1_STATE_UPDATERS_TRON=T...,T...                  # Comma-separated updater addresses
SP1_VKEY_UPDATER_TRON=T...                         # VKey updater address
SP1_CONSENSUS_RPCS_LIST_TRON=https://...           # Comma-separated beacon chain RPC URLs
```

```bash
yarn tron-deploy-sp1-helios [--testnet] [--fee-limit <sun>]
```

> **Warning:** Once SP1Helios is deployed, you have 7 days to deploy the Universal_SpokePool and activate it in-protocol. After 7 days with no update, the contract becomes immutable.

### Universal_SpokePool

Deploys the implementation contract and wraps it in a UUPS ERC1967Proxy, matching the behavior of `DeployUniversalSpokePool.s.sol`. Constructor params like wrapped native token (WTRX), time buffers, and HubPoolStore address are read from `generated/constants.json` and `broadcast/deployed-addresses.json`. If a Tron `SpokePool` proxy is already recorded for the current chain, the script skips deploying a new proxy and only deploys a fresh implementation.

```bash
yarn tron-deploy-universal-spokepool <sp1-helios-address> [--testnet]
```

### Universal deployment order

1. **SP1AutoVerifier** (testnet only) or wait for Succinct to deploy the real Groth16 verifier
2. **SP1Helios** — needs the verifier address
3. **Universal_SpokePool** — needs the SP1Helios address

## Counterfactual Deposit Scripts

### CounterfactualDepositFactoryTron

Tron-compatible factory with corrected CREATE2 address prediction (0x41 prefix). No constructor args.

```bash
yarn tron-deploy-counterfactual-factory [--testnet]
```

### CounterfactualDeposit

Clone implementation contract used by the factory. No constructor args. Must be deployed before creating clones.

```bash
yarn tron-deploy-counterfactual-deposit [--testnet]
```

### CounterfactualDepositSpokePool

```bash
yarn tron-deploy-counterfactual-deposit-spokepool <spokePool> <signer> <wrappedNativeToken> [--testnet]
```

### AdminWithdrawManager

```bash
yarn tron-deploy-admin-withdraw-manager <owner> <directWithdrawer> <signer> [--testnet]
```

### WithdrawImplementation

```bash
yarn tron-deploy-withdraw-implementation [--testnet]
```

### Deploy Clone

Deploys a clone from the factory and verifies the predicted address matches the actual deployed address.

```bash
yarn tron-deploy-counterfactual-clone <factory> <implementation> <merkleRoot> <salt> [--testnet]
```

## Periphery Scripts

### SpokePoolPeriphery

Deploys `SpokePoolPeriphery`. The constructor internally deploys a `SwapProxy`, which is accessible via `spokePoolPeriphery.swapProxy()` — a separate `SwapProxy` deployment is not required when deploying the periphery.

```bash
yarn tron-deploy-spoke-pool-periphery <permit2> [--testnet]
```

### SwapProxy

Deploys a standalone `SwapProxy`. Use this only if a dedicated `SwapProxy` is needed outside of a periphery deployment (the periphery's constructor already deploys its own).

```bash
yarn tron-deploy-swap-proxy <permit2> [--testnet]
```

## Verifying contracts on TronScan

TronScan requires a single flattened Solidity file for verification. Flatten with `forge flatten` and fix the merged pragma:

```bash
forge flatten contracts/sp1-helios/SP1Helios.sol | sed 's/pragma solidity .*/pragma solidity ^0.8.25;/' > flattened/SP1Helios.sol
forge flatten contracts/Universal_SpokePool.sol | sed 's/pragma solidity .*/pragma solidity ^0.8.25;/' > flattened/Universal_SpokePool.sol
```

Then verify on TronScan:

1. Go to the contract page on [TronScan](https://tronscan.org) (or [Nile TronScan](https://nile.tronscan.org) for testnet)
2. Click **Contract** → **Verify and Publish**
3. Select **Solidity (Single file)**
4. Set compiler version to **0.8.25** (must match Tron's solc)
5. Set EVM version to **cancun**
6. Set optimization to **Yes**, runs **800**, via-ir **enabled**
7. Paste the flattened source
8. If the contract has constructor args, provide the ABI-encoded args (logged during deployment as `Constructor args: 0x...`)

> **Tip:** The `flattened/` directory is gitignored. Regenerate flattened sources from the current contract code before verifying.

## Broadcast artifacts

Each deployment writes a Foundry-compatible broadcast artifact to `broadcast/TronDeploy<ContractName>.s.sol/<chainId>/`. These track deployed addresses and transaction IDs.

## File overview

| File                                                             | Purpose                                                                |
| ---------------------------------------------------------------- | ---------------------------------------------------------------------- |
| `deploy.ts`                                                      | Shared TronWeb deployer — reads Foundry artifacts, deploys via TronWeb |
| `universal/tron-deploy-sp1-auto-verifier.ts`                     | Deploys SP1AutoVerifier (no args)                                      |
| `universal/tron-deploy-sp1-helios.ts`                            | Deploys SP1Helios with genesis binary                                  |
| `universal/tron-deploy-universal-spokepool.ts`                   | Deploys Universal_SpokePool implementation + ERC1967Proxy              |
| `counterfactual/tron-deploy-counterfactual-factory.ts`           | Deploys CounterfactualDepositFactoryTron (no args)                     |
| `counterfactual/tron-deploy-counterfactual-deposit.ts`           | Deploys CounterfactualDeposit implementation (no args)                 |
| `counterfactual/tron-deploy-counterfactual-deposit-spokepool.ts` | Deploys CounterfactualDepositSpokePool                                 |
| `counterfactual/tron-deploy-admin-withdraw-manager.ts`           | Deploys AdminWithdrawManager                                           |
| `counterfactual/tron-deploy-withdraw-implementation.ts`          | Deploys WithdrawImplementation (no args)                               |
| `counterfactual/tron-deploy-counterfactual-clone.ts`             | Deploys a clone from factory, verifies address prediction              |
| `periphery/tron-deploy-spoke-pool-periphery.ts`                  | Deploys SpokePoolPeriphery (constructor also deploys inner SwapProxy)  |
| `periphery/tron-deploy-swap-proxy.ts`                            | Deploys a standalone SwapProxy                                         |

## Chain IDs

| Network      | Chain ID   |
| ------------ | ---------- |
| Tron Mainnet | 728126428  |
| Tron Nile    | 3448148188 |
