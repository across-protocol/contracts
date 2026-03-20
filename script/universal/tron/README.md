# Tron Deployment Scripts

TypeScript scripts for deploying contracts to Tron via TronWeb. Tron uses a protobuf transaction format (not RLP) and SHA-256 signing (not keccak256), so Foundry's `forge script --broadcast` cannot deploy directly — these scripts handle that.

## Prerequisites

### 1. Tron solc binary

Download Tron's custom solc 0.8.25 from [tronprotocol/solidity releases](https://github.com/tronprotocol/solidity/releases) and place it at `bin/solc-tron`:

```bash
# macOS (Apple Silicon)
curl -L -o bin/solc-tron https://github.com/nicetip/solidity/releases/download/tv0.8.25/solc_macos
chmod +x bin/solc-tron

# Linux (amd64)
curl -L -o bin/solc-tron https://github.com/nicetip/solidity/releases/download/tv0.8.25/solc_linux
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
yarn build-tron-universal
```

This runs `FOUNDRY_PROFILE=tron-universal forge build`, which compiles using Tron's solc (`bin/solc-tron`) and outputs Foundry artifacts to `out-tron-universal/`.

### 3. Environment variables

Create a `.env` file (or `source .env` before running):

```bash
# Required for all deployments
MNEMONIC="your twelve word mnemonic phrase here"
NODE_URL_728126428=https://api.trongrid.io        # Tron mainnet
NODE_URL_3448148188=https://nile.trongrid.io       # Tron Nile testnet

# Optional
TRON_FEE_LIMIT=1500000000  # Fee limit in sun (default: 1500 TRX)
```

> **Important:** Use the base TronGrid URL (`https://api.trongrid.io`), NOT the `/jsonrpc` endpoint. TronWeb needs the native Tron API, not the Ethereum-compatible JSON-RPC endpoint.

## Deploy Scripts

### SP1AutoVerifier

No-op verifier for testing SP1Helios without real ZK proofs. No constructor args.

```bash
yarn tron-deploy-sp1-auto-verifier <chain-id>

# Example: deploy to Nile testnet
yarn tron-deploy-sp1-auto-verifier 3448148188
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
yarn tron-deploy-sp1-helios <chain-id>
```

> **Warning:** Once SP1Helios is deployed, you have 7 days to deploy the Universal_SpokePool and activate it in-protocol. After 7 days with no update, the contract becomes immutable.

### Universal_SpokePool

Deploys the implementation contract (not the proxy). Must be wrapped in a UUPS proxy and initialized separately.

Additional env vars:

```bash
USP_ADMIN_UPDATE_BUFFER=86400                      # Admin update buffer (seconds), e.g. 24h
USP_HELIOS_ADDRESS=T...                            # Deployed SP1Helios address
USP_HUB_POOL_STORE_ADDRESS=T...                    # HubPoolStore address
USP_WRAPPED_NATIVE_TOKEN_ADDRESS=T...              # WTRX address
USP_DEPOSIT_QUOTE_TIME_BUFFER=3600                 # Deposit quote time buffer (seconds)
USP_FILL_DEADLINE_BUFFER=21600                     # Fill deadline buffer (seconds)
USP_L2_USDC_ADDRESS=T...                           # USDC on Tron
USP_CCTP_TOKEN_MESSENGER_ADDRESS=T...              # CCTP TokenMessenger, or zero address
USP_OFT_DST_EID=0                                  # LayerZero OFT endpoint ID, 0 to disable
USP_OFT_FEE_CAP=0                                  # OFT fee cap in wei, 0 to disable
```

```bash
yarn tron-deploy-universal-spokepool <chain-id>
```

## Deployment order

1. **SP1AutoVerifier** (testnet only) or wait for Succinct to deploy the real Groth16 verifier
2. **SP1Helios** — needs the verifier address
3. **Universal_SpokePool** — needs the SP1Helios address

## Verifying contracts on TronScan

TronScan requires a single flattened Solidity file for verification. Use `forge flatten`:

```bash
# Flatten a contract
forge flatten contracts/sp1-helios/SP1Helios.sol > flattened/SP1Helios.sol
forge flatten contracts/sp1-helios/SP1AutoVerifier.sol > flattened/SP1AutoVerifier.sol
forge flatten contracts/Universal_SpokePool.sol > flattened/Universal_SpokePool.sol
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

## Chain IDs

| Network      | Chain ID   |
| ------------ | ---------- |
| Tron Mainnet | 728126428  |
| Tron Nile    | 3448148188 |
