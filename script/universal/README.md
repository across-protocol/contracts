# Universal SpokePool & SP1Helios Deployment

This guide covers deploying the **Universal SpokePool** infrastructure to a new chain. The system uses SP1 zero-knowledge proofs via the SP1Helios light client for cross-chain message verification.

## Prerequisites

- **Foundry** installed with FFI enabled
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

## Combined Deployment (Recommended)

This script deploys SP1Helios, deploys the Universal_SpokePool (passing the SP1Helios address directly), and transfers the SP1Helios `VKEY_UPDATER_ROLE` and `DEFAULT_ADMIN_ROLE` from the deployer to the SpokePool. It assumes a fresh deployment with no existing SpokePool on the target chain. Omit `--broadcast` for a dry run.

```bash
./script/universal/DeploySP1HeliosAndUniversalSpokePool.sh \
  --rpc-url <NEW_CHAIN_RPC_URL> \
  --oft-fee-cap <OFT_FEE_CAP> \
  --etherscan-api-key <API_KEY> \
  --broadcast
```

---

## Manual Deployment (Step-by-Step)

If you need more control over individual steps, you can run each deployment separately.

### Step 1: Deploy SP1Helios

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

> **Note**: The `--ffi` flag is required. The script downloads a genesis binary, verifies its checksum, and runs it to generate genesis parameters.

Note the deployed **SP1Helios address** from the output.

---

### Step 2: Deploy Universal SpokePool

Pass the SP1Helios address from Step 1 as the first argument:

```bash
forge script script/universal/DeployUniversalSpokePool.s.sol:DeployUniversalSpokePool \
  --sig "run(address,uint256)" <SP1_HELIOS_ADDRESS> <OFT_FEE_CAP> \
  --rpc-url <NEW_CHAIN_RPC_URL> \
  --broadcast \
  --verify \
  --etherscan-api-key <API_KEY> \
  -vvvv
```

Replace `<SP1_HELIOS_ADDRESS>` with the address from Step 1 and `<OFT_FEE_CAP>` with the maximum fee for OFT (LayerZero) transfers (e.g., `78000`).

Note the deployed **Universal_SpokePool proxy address** from the output.

---

### Step 3: Transfer SP1Helios Roles to SpokePool

The SP1Helios contract uses OpenZeppelin's AccessControl. After deployment, the deployer holds the `DEFAULT_ADMIN_ROLE` and `VKEY_UPDATER_ROLE`. Both roles must be transferred to the Universal_SpokePool so that admin functions (including verification key updates) can be called through the cross-chain admin flow.

The `VKEY_UPDATER_ROLE` must be granted and renounced **before** the `DEFAULT_ADMIN_ROLE` is transferred, since the deployer needs admin privileges to grant roles.

```bash
VKEY_UPDATER_ROLE=$(cast keccak "VKEY_UPDATER_ROLE")
DEFAULT_ADMIN_ROLE=0x0000000000000000000000000000000000000000000000000000000000000000

# Grant VKEY_UPDATER_ROLE to the SpokePool
cast send <SP1_HELIOS_ADDRESS> \
  "grantRole(bytes32,address)" \
  $VKEY_UPDATER_ROLE \
  <SPOKE_POOL_ADDRESS> \
  --rpc-url <NEW_CHAIN_RPC_URL> \
  --private-key <DEPLOYER_PRIVATE_KEY>

# Renounce VKEY_UPDATER_ROLE from the deployer
cast send <SP1_HELIOS_ADDRESS> \
  "renounceRole(bytes32,address)" \
  $VKEY_UPDATER_ROLE \
  <DEPLOYER_ADDRESS> \
  --rpc-url <NEW_CHAIN_RPC_URL> \
  --private-key <DEPLOYER_PRIVATE_KEY>

# Grant DEFAULT_ADMIN_ROLE to the SpokePool
cast send <SP1_HELIOS_ADDRESS> \
  "grantRole(bytes32,address)" \
  $DEFAULT_ADMIN_ROLE \
  <SPOKE_POOL_ADDRESS> \
  --rpc-url <NEW_CHAIN_RPC_URL> \
  --private-key <DEPLOYER_PRIVATE_KEY>

# Renounce DEFAULT_ADMIN_ROLE from the deployer
cast send <SP1_HELIOS_ADDRESS> \
  "renounceRole(bytes32,address)" \
  $DEFAULT_ADMIN_ROLE \
  <DEPLOYER_ADDRESS> \
  --rpc-url <NEW_CHAIN_RPC_URL> \
  --private-key <DEPLOYER_PRIVATE_KEY>
```

> **Note**: `DEFAULT_ADMIN_ROLE` (`0x00...00`) is defined in OpenZeppelin's AccessControl. `VKEY_UPDATER_ROLE` is `keccak256("VKEY_UPDATER_ROLE")`.
