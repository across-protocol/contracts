# Universal SpokePool & SP1Helios Deployment

This guide covers deploying the **Universal SpokePool** infrastructure to a new chain. The system uses SP1 zero-knowledge proofs via the SP1Helios light client for cross-chain message verification.

## Prerequisites

- **Foundry** installed with FFI enabled
- **jq** installed (used by the combined deployment script to parse broadcast JSON)
- **curl** and **sha256sum** available in PATH
- Access to Ethereum consensus layer RPC endpoints (beacon nodes)
- A funded deployer wallet (via mnemonic)
- `generated/constants.json` with chain configuration (run `yarn generate-constants` if missing)

## A Note to Deployers

When you deploy a new Universal Spoke pool to be used by Across, there is a time limit you must follow from Sp1Helios deployment to config store activation.
The SP1Helios contract has a constant `MAX_SLOT_AGE = 7 days`, which is the upper-bound on how long updates may be spaced apart from each other. If the `stateUpdater` is not actively updating helios within seven days of deployment, the Sp1Helios contract will revert to a state where no further updates can be made, and by extension the Universal spoke will become inert and must be upgraded by the `owner` (where the upgrade implementation candidate has a fresh Sp1Helios contract set in its constructor).

## Environment Variables

Create a `.env` file with the following variables:

| Variable                  | Description                                                                     |
| ------------------------- | ------------------------------------------------------------------------------- |
| `MNEMONIC`                | BIP-39 mnemonic to derive the deployer's private key (uses index 0)             |
| `SP1_RELEASE`             | Genesis binary version (e.g., `0.1.0-alpha.20`)                                 |
| `SP1_PROVER_MODE`         | SP1 prover type: `mock`, `cpu`, `cuda`, or `network`                            |
| `SP1_VERIFIER_ADDRESS`    | Address of the SP1 verifier contract (use `0x0` to auto-deploy a mock verifier) |
| `SP1_STATE_UPDATERS`      | Comma-separated list of addresses authorized to submit state updates            |
| `SP1_VKEY_UPDATER`        | Address authorized to update the verification key                               |
| `SP1_CONSENSUS_RPCS_LIST` | Comma-separated list of Ethereum consensus (beacon) RPC URLs                    |

---

## Deployment Scripts

There are three scripts in this directory:

| Script                                       | Purpose                                                                                                    |
| -------------------------------------------- | ---------------------------------------------------------------------------------------------------------- |
| `DeploySP1HeliosAndUniversalSpokePool.s.sol` | **Combined orchestrator** — runs Steps 1–3 below in sequence via FFI, plus optional Etherscan verification |
| `DeploySP1Helios.s.sol`                      | Deploys the SP1Helios light client (downloads genesis binary via FFI, verifies checksum, deploys contract) |
| `DeployUniversalSpokePool.s.sol`             | Deploys the Universal_SpokePool behind an ERC1967 proxy using DeploymentUtils                              |

---

## Combined Deployment (Recommended)

`DeploySP1HeliosAndUniversalSpokePool.s.sol` orchestrates the full deployment flow:

1. Runs `forge clean && forge build` to ensure a fresh build for OZ proxy validation
2. Invokes `DeploySP1Helios.s.sol` via FFI to deploy the light client
3. Invokes `DeployUniversalSpokePool.s.sol` via FFI to deploy the SpokePool proxy
4. Transfers `VKEY_UPDATER_ROLE` and `DEFAULT_ADMIN_ROLE` from deployer to SpokePool via `cast send`
5. Verifies role transfers via `cast call`
6. Optionally verifies contracts on Etherscan via `forge script --resume --verify`

Each sub-script runs as its own `forge script` process, so broadcast artifacts land in the expected directories (`broadcast/DeploySP1Helios.s.sol/...` and `broadcast/DeployUniversalSpokePool.s.sol/...`).

**Broadcast + verify:**

```bash
forge script script/universal/DeploySP1HeliosAndUniversalSpokePool.s.sol \
  --sig "run(uint256,string,string,bool)" \
  <OFT_FEE_CAP> <RPC_URL> <ETHERSCAN_API_KEY> true \
  --ffi
```

**Dry run** (simulation only, no on-chain transactions):

```bash
forge script script/universal/DeploySP1HeliosAndUniversalSpokePool.s.sol \
  --sig "run(uint256,string,string,bool)" \
  <OFT_FEE_CAP> <RPC_URL> "" false \
  --ffi
```

The script aborts if a SpokePool is already registered for the target chain in `broadcast/deployed-addresses.json`. Remove the chain entry from that file if you need to redeploy.

> **Note**: The `--ffi` flag is required. Do **not** pass `--broadcast` or `--rpc-url` to the outer script — deployments and role transfers are handled internally via FFI sub-processes and `cast send`.

---

## Individual Script Usage

If you need more control over individual steps (e.g., deploying SP1Helios on one chain while reusing an existing SpokePool, or debugging a single step), you can run each script separately.

### DeploySP1Helios.s.sol

Deploys the SP1Helios light client contract. Downloads a genesis binary from GitHub releases (verified against `checksums.json`), runs it to generate genesis parameters, and deploys the contract. If `SP1_VERIFIER_ADDRESS` is `0x0`, a mock verifier is deployed automatically.

```bash
forge script script/universal/DeploySP1Helios.s.sol \
  --rpc-url <RPC_URL> \
  --broadcast \
  --verify --etherscan-api-key <API_KEY> \
  --ffi \
  -vvvv
```

The `--ffi` flag is required for the genesis binary download and execution. The script returns the deployed SP1Helios address.

### DeployUniversalSpokePool.s.sol

Deploys the Universal_SpokePool behind an ERC1967 proxy. Requires the SP1Helios address from the step above. Reads chain-specific configuration (WETH, USDC, CCTP, OFT) from `generated/constants.json` and `broadcast/deployed-addresses.json`.

```bash
forge script script/universal/DeployUniversalSpokePool.s.sol:DeployUniversalSpokePool \
  --sig "run(address,uint256)" <SP1_HELIOS_ADDRESS> <OFT_FEE_CAP> \
  --rpc-url <RPC_URL> \
  --broadcast \
  --verify --etherscan-api-key <API_KEY> \
  -vvvv
```

After deployment, you must transfer SP1Helios roles to the SpokePool (see below).

### Transferring SP1Helios Roles to SpokePool

The SP1Helios contract uses OpenZeppelin's AccessControl. After deployment, the deployer holds `DEFAULT_ADMIN_ROLE` and `VKEY_UPDATER_ROLE`. Both must be transferred to the Universal_SpokePool so that admin functions (including verification key updates) can be called through the cross-chain admin flow.

The `VKEY_UPDATER_ROLE` must be granted and renounced **before** `DEFAULT_ADMIN_ROLE` is transferred, since the deployer needs admin privileges to grant roles.

```bash
VKEY_UPDATER_ROLE=$(cast keccak "VKEY_UPDATER_ROLE")
DEFAULT_ADMIN_ROLE=0x0000000000000000000000000000000000000000000000000000000000000000

# Grant VKEY_UPDATER_ROLE to the SpokePool
cast send <SP1_HELIOS_ADDRESS> \
  "grantRole(bytes32,address)" $VKEY_UPDATER_ROLE <SPOKE_POOL_ADDRESS> \
  --rpc-url <RPC_URL> --private-key <DEPLOYER_PRIVATE_KEY>

# Renounce VKEY_UPDATER_ROLE from the deployer
cast send <SP1_HELIOS_ADDRESS> \
  "renounceRole(bytes32,address)" $VKEY_UPDATER_ROLE <DEPLOYER_ADDRESS> \
  --rpc-url <RPC_URL> --private-key <DEPLOYER_PRIVATE_KEY>

# Grant DEFAULT_ADMIN_ROLE to the SpokePool
cast send <SP1_HELIOS_ADDRESS> \
  "grantRole(bytes32,address)" $DEFAULT_ADMIN_ROLE <SPOKE_POOL_ADDRESS> \
  --rpc-url <RPC_URL> --private-key <DEPLOYER_PRIVATE_KEY>

# Renounce DEFAULT_ADMIN_ROLE from the deployer
cast send <SP1_HELIOS_ADDRESS> \
  "renounceRole(bytes32,address)" $DEFAULT_ADMIN_ROLE <DEPLOYER_ADDRESS> \
  --rpc-url <RPC_URL> --private-key <DEPLOYER_PRIVATE_KEY>
```
