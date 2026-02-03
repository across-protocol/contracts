# Universal SpokePool & SP1Helios Deployment

This guide covers deploying the **Universal SpokePool** infrastructure to a new chain. The system uses SP1 zero-knowledge proofs via the SP1Helios light client for cross-chain message verification.

## Prerequisites

- **Foundry** installed with FFI enabled
- **curl** and **sha256sum** available in PATH
- Access to Ethereum consensus layer RPC endpoints (beacon nodes)
- A funded deployer wallet (via mnemonic)
- `generated/constants.json` with chain configuration (run `yarn generate-constants` if missing)

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

> **Note**: The `--ffi` flag is required. The script downloads a genesis binary, verifies its checksum, and runs it to generate genesis parameters.

Note the deployed **SP1Helios address** from the output.

---

## Step 2: Update Deployed Addresses

After the forge script completes, update `deployed-addresses.json` so the SpokePool deployment can find the SP1Helios address:

```bash
yarn extract-addresses
```

---

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

Replace `<OFT_FEE_CAP>` with the maximum fee for OFT (LayerZero) transfers (e.g., `78000`).

Note the deployed **Universal_SpokePool proxy address** from the output.

---

## Step 4: Transfer SP1Helios Admin Role to SpokePool

The SP1Helios contract uses OpenZeppelin's AccessControl. After deployment, the deployer holds the `DEFAULT_ADMIN_ROLE`. This role must be transferred to the Universal_SpokePool so that admin functions can be called through the cross-chain admin flow.

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
