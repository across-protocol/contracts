# Universal Deployment Scripts

This directory contains deployment scripts for the **Universal SpokePool** infrastructure—a chain-agnostic spoke pool system that uses SP1 zero-knowledge proofs for cross-chain message verification.

## Scripts Overview

| Script                           | Purpose                                     |
| -------------------------------- | ------------------------------------------- |
| `DeploySP1Helios.s.sol`          | Deploys the SP1Helios light client contract |
| `DeployUniversalSpokePool.s.sol` | Deploys the Universal_SpokePool contract    |

## Deployment Order

For a new chain, deploy in this order:

1. **SP1Helios** - The light client that verifies Ethereum L1 state
2. **Universal_SpokePool** - The spoke pool that uses Helios for admin verification

---

# SP1Helios Deployment

The `DeploySP1Helios.s.sol` script deploys the SP1Helios contract—a light client that verifies Ethereum consensus state using SP1 zero-knowledge proofs.

## What It Does

1. Downloads a pre-built genesis binary from GitHub releases
2. Verifies the binary's SHA256 checksum for security
3. Runs the binary to generate genesis parameters from the Ethereum consensus layer
4. Deploys the SP1Helios contract with those parameters

## Prerequisites

- **Foundry** installed with FFI enabled
- **curl** available in PATH (for downloading binaries)
- **sha256sum** available in PATH (for checksum verification)
- Access to Ethereum consensus layer RPC endpoints (beacon nodes)
- A funded deployer wallet (via mnemonic)

## Environment Variables

| Variable                  | Required | Description                                                                     |
| ------------------------- | -------- | ------------------------------------------------------------------------------- |
| `MNEMONIC`                | Yes      | BIP-39 mnemonic to derive the deployer's private key (uses index 0)             |
| `SP1_RELEASE`             | Yes      | Genesis binary version (e.g., `0.1.0-alpha.20`)                                 |
| `SP1_PROVER_MODE`         | Yes      | SP1 prover type: `mock`, `cpu`, `cuda`, or `network`                            |
| `SP1_VERIFIER_ADDRESS`    | Yes      | Address of the SP1 verifier contract (use `0x0` to auto-deploy a mock verifier) |
| `SP1_STATE_UPDATERS`      | Yes      | Comma-separated list of addresses authorized to submit state updates            |
| `SP1_VKEY_UPDATER`        | Yes      | Address authorized to update the verification key                               |
| `SP1_CONSENSUS_RPCS_LIST` | Yes      | Comma-separated list of Ethereum consensus (beacon) RPC URLs                    |

### Example `.env` for SP1Helios

```bash
MNEMONIC="your twelve word mnemonic phrase goes here with spaces"
SP1_RELEASE="0.1.0-alpha.20"
SP1_PROVER_MODE="network"
SP1_VERIFIER_ADDRESS="0x397A5f7f3dBd538f23DE225B51f532c34448dA9B"
SP1_STATE_UPDATERS="0xf7bac63fc7ceacf0589f25454ecf5c2ce904997c"
SP1_VKEY_UPDATER="0x9a8f92a830a5cb89a3816e3d267cb7791c16b04d"
SP1_CONSENSUS_RPCS_LIST="https://ethereum-mainnet.core.chainstack.com/beacon/YOUR_KEY,https://lodestar-mainnet.chainsafe.io"
```

## Running SP1Helios Deployment

```bash
forge script script/universal/DeploySP1Helios.s.sol \
  --rpc-url <RPC_URL> \
  --broadcast \
  --verify \
  --etherscan-api-key <API_KEY> \
  --ffi \
  -vvvv
```

> **Note**: The `--ffi` flag is **required** as the script uses Foundry's FFI to execute shell commands (curl, chmod, sha256sum, and the genesis binary).

## SP1Helios Behind the Scenes

### Step 1: Platform Detection

The script detects your operating system using `uname -s` and selects the appropriate binary:

- **macOS**: `genesis_{version}_arm64_darwin`
- **Linux**: `genesis_{version}_amd64_linux`

### Step 2: Binary Download

The genesis binary is downloaded from:

```
https://github.com/across-protocol/sp1-helios/releases/download/v{version}/{binary_name}
```

The binary is saved to `script/universal/genesis-binary`.

### Step 3: Checksum Verification

Before execution, the script verifies the downloaded binary against known-good checksums stored in `checksums.json`:

```json
{
  "genesis_0.1.0-alpha.20_amd64_linux": "312d253ce...",
  "genesis_0.1.0-alpha.20_arm64_darwin": "38607203e..."
}
```

If the checksum doesn't match, the script aborts.

### Step 4: Genesis Binary Execution

The genesis binary connects to the Ethereum consensus layer RPCs and:

1. Fetches the current sync committee information
2. Gets the latest finalized header
3. Retrieves execution state roots
4. Generates the SP1 verification key

The output is written to `script/universal/genesis.json` containing:

- `executionStateRoot` - Current execution layer state root
- `genesisTime` - Beacon chain genesis timestamp
- `head` - Current head slot number
- `header` - Beacon block header hash
- `heliosProgramVkey` - SP1 program verification key
- `secondsPerSlot` - Slot duration (12 seconds on mainnet)
- `slotsPerEpoch` - Slots per epoch (32 on mainnet)
- `slotsPerPeriod` - Slots per sync committee period (8192 on mainnet)
- `syncCommitteeHash` - Current sync committee commitment
- `verifier` - SP1 verifier contract address
- `vkeyUpdater` - Address that can update the vkey
- `updaters` - Array of state updater addresses

### Step 5: Contract Deployment

The script reads `genesis.json` and deploys the SP1Helios contract with the genesis parameters. If `SP1_VERIFIER_ADDRESS` was set to `0x0`, it automatically deploys a `SP1MockVerifier` for testing purposes.

---

# Universal SpokePool Deployment

The `DeployUniversalSpokePool.s.sol` script deploys the Universal_SpokePool contract—a chain-agnostic spoke pool that verifies admin messages from L1 using the SP1Helios light client.

## What It Does

1. Reads deployment configuration from `constants.json`
2. Automatically detects chain-specific addresses (USDC, CCTP, wrapped native token, etc.)
3. Deploys the Universal_SpokePool implementation and proxy
4. Initializes the proxy with the HubPool as cross-domain admin

## Prerequisites

- **Foundry** installed
- `generated/constants.json` file with chain configuration
- SP1Helios already deployed on the target chain
- A funded deployer wallet (via mnemonic)

## Environment Variables

| Variable   | Required | Description                                                         |
| ---------- | -------- | ------------------------------------------------------------------- |
| `MNEMONIC` | Yes      | BIP-39 mnemonic to derive the deployer's private key (uses index 0) |

## Running Universal SpokePool Deployment

The script requires an `oftFeeCap` parameter that sets the maximum fee for OFT (Omnichain Fungible Token) transfers.

### Dry Run (Simulation)

```bash
source .env
forge script script/universal/DeployUniversalSpokePool.s.sol:DeployUniversalSpokePool \
  --sig "run(uint256)" <OFT_FEE_CAP> \
  --rpc-url <RPC_URL> \
  -vvvv
```

### Broadcast to Network

```bash
source .env
forge script script/universal/DeployUniversalSpokePool.s.sol:DeployUniversalSpokePool \
  --sig "run(uint256)" <OFT_FEE_CAP> \
  --rpc-url <RPC_URL> \
  --broadcast \
  -vvvv
```

### Example with Specific Values

```bash
# OFT_FEE_CAP of 78000 (example value)
forge script script/universal/DeployUniversalSpokePool.s.sol:DeployUniversalSpokePool \
  --sig "run(uint256)" 78000 \
  --rpc-url $NODE_URL \
  --broadcast \
  -vvvv
```

## Universal SpokePool Behind the Scenes

### Step 1: Load Deployment Configuration

The script uses `DeploymentUtils` to load chain-specific configuration from `generated/constants.json`:

- Spoke chain ID (from RPC)
- Hub chain ID
- HubPool address

### Step 2: Resolve Chain-Specific Addresses

Based on the spoke chain ID, the script automatically resolves:

- **Wrapped Native Token** - WETH, WBNB, etc. depending on the chain (from `constants.json`)
- **USDC Address** - Native USDC on the chain (from `constants.json`)
- **Helios Address** - The deployed SP1Helios light client (from `deployed-addresses.json`)
- **HubPoolStore Address** - L1 contract storing relay message hashes (from `constants.json`)
- **CCTP Token Messenger** - Circle's CCTP v2 messenger if available (from `constants.json`)
- **OFT Endpoint ID** - LayerZero endpoint ID for the hub chain (from `constants.json`)

### Step 3: Prepare Constructor Arguments

The Universal_SpokePool constructor receives:

| Parameter                        | Description                                      |
| -------------------------------- | ------------------------------------------------ |
| `heliosAdminBufferUpdateSeconds` | Grace period for admin updates (1 day)           |
| `helios`                         | SP1Helios light client address                   |
| `l1HubPoolStore`                 | L1 HubPoolStore contract address                 |
| `wrappedNativeToken`             | Chain's wrapped native token (e.g., WETH)        |
| `depositQuoteTimeBuffer`         | Time buffer for deposit quotes                   |
| `fillDeadlineBuffer`             | Buffer for fill deadlines                        |
| `usdcAddress`                    | USDC token address                               |
| `cctpTokenMessenger`             | CCTP v2 messenger (or address(0) if unavailable) |
| `oftDstEid`                      | LayerZero destination endpoint ID                |
| `oftFeeCap`                      | Maximum OFT transfer fee (script parameter)      |

### Step 4: Deploy Proxy

The script deploys:

1. **Implementation** - The Universal_SpokePool logic contract
2. **Proxy** - An upgradeable proxy pointing to the implementation

### Step 5: Initialize

The proxy is initialized with:

- `initialDepositId = 1`
- `crossDomainAdmin = HubPool address`
- `withdrawalRecipient = HubPool address`

---

# Full Deployment to a New Chain

This section covers the complete end-to-end process for deploying the Universal SpokePool infrastructure to a new chain.

## Step 1: Deploy SP1Helios

Deploy the SP1Helios light client contract:

```bash
forge script script/universal/DeploySP1Helios.s.sol \
  --rpc-url <NEW_CHAIN_RPC_URL> \
  --broadcast \
  --verify \
  --etherscan-api-key <API_KEY> \
  --ffi \
  -vvvv
```

Note the deployed SP1Helios address from the output.

## Step 2: Update Deployed Addresses

After the forge script completes, update `deployed-addresses.json` so the SpokePool deployment can find the SP1Helios address:

```bash
yarn extract-addresses
```

## Step 3: Deploy Universal SpokePool

The script reads the SP1Helios address from `broadcast/deployed-addresses.json`.

```bash
forge script script/universal/DeployUniversalSpokePool.s.sol:DeployUniversalSpokePool \
  --sig "run(uint256)" <OFT_FEE_CAP> \
  --rpc-url <NEW_CHAIN_RPC_URL> \
  --broadcast \
  --verify \
  --etherscan-api-key <API_KEY> \
  -vvvv
```

Note the deployed Universal_SpokePool proxy address from the output.

## Step 4: Transfer SP1Helios Admin Role to SpokePool

The SP1Helios contract uses OpenZeppelin's AccessControl. After deployment, the deployer holds the `DEFAULT_ADMIN_ROLE`. This role must be transferred to the Universal_SpokePool so that admin functions can be called through the cross-chain admin flow.

Using cast:

```bash
# Grant DEFAULT_ADMIN_ROLE to the SpokePool
cast send <SP1_HELIOS_ADDRESS> \
  "grantRole(bytes32,address)" \
  0x0000000000000000000000000000000000000000000000000000000000000000 \
  <SPOKE_POOL_ADDRESS> \
  --rpc-url <NEW_CHAIN_RPC_URL> \
  --private-key <DEPLOYER_PRIVATE_KEY>

# Renounce DEFAULT_ADMIN_ROLE from the deployer
cast send <SP1_HELIOS_ADDRESS> \
  "renounceRole(bytes32,address)" \
  0x0000000000000000000000000000000000000000000000000000000000000000 \
  <DEPLOYER_ADDRESS> \
  --rpc-url <NEW_CHAIN_RPC_URL> \
  --private-key <DEPLOYER_PRIVATE_KEY>
```

> **Note**: `0x00...00` (32 zero bytes) is the `DEFAULT_ADMIN_ROLE` constant defined in OpenZeppelin's AccessControl.

## Verification Checklist

After completing all steps, verify:

- [ ] SP1Helios is deployed and verified on block explorer
- [ ] Universal_SpokePool proxy and implementation are deployed and verified
- [ ] SP1Helios `DEFAULT_ADMIN_ROLE` is held by the SpokePool (not the deployer)
- [ ] SpokePool's `crossDomainAdmin` is set to the HubPool address
- [ ] `yarn extract-addresses` has been run and both contracts appear in `deployed-addresses.json`

---
