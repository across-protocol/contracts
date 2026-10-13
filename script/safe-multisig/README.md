# Safe Multisig

TypeScript helpers for deterministic Safe deployments that still emit Foundry-style broadcast artifacts.

## Files

- `deploySafe.ts` - Deploys the named multisig's Safe using its committed config and writes a Foundry-style broadcast artifact
- `config/<name>.json` - Owners, threshold, and salt nonce for each multisig (`operations.json`, `product.json`, ...)
- `canonicalSafeInfraAddresses.json` - Canonical Safe v1.4.1 contract addresses (SafeL2 singleton) for chains missing from the safe-deployments registry
- `broadcast.ts` - Foundry-style broadcast writer for the Safe deployment transaction

## Usage

```bash
# Operations multisig (the default)
yarn deploy-safe --chain-id 1

# Product multisig
yarn deploy-safe --chain-id 1 --name product

# For chains not in protocol-kit's safe-deployments registry (e.g. Arc):
yarn deploy-safe --chain-id 5042 --use-canonical-infra
```

`--name` selects the multisig to deploy (default `operations`). The script reads `script/safe-multisig/config/<name>.json` and loads `MNEMONIC`, `NODE_URL_<chainId>`, and `CUSTOM_NODE_URL` from the repo `.env`.

## Multisig names and artifacts

Each multisig has its own config, broadcast folder, and `deployed-addresses.json` key, so deploying one never overwrites another:

| `--name`     | Config                   | Broadcast folder                               | Address key    |
| ------------ | ------------------------ | ---------------------------------------------- | -------------- |
| `operations` | `config/operations.json` | `broadcast/DeploySafe.s.sol/<chainId>`         | `Safe`         |
| `product`    | `config/product.json`    | `broadcast/DeploySafe_Product.s.sol/<chainId>` | `Safe_Product` |

The operations Safe keeps the unsuffixed names for backwards compatibility (e.g. `CheckCounterfactualDeployments.s.sol` reads `Safe`). Any other name maps to `DeploySafe_<PascalName>.s.sol` and `Safe_<PascalName>`, which `yarn extract-addresses` recognises automatically. To add a multisig, drop a new `config/<name>.json` in place; no code changes are needed.

Because the Safe address is CREATE2 over owners, threshold, and salt nonce, different multisigs land at different addresses even with the same `saltNonce`.

## Config

The config is committed because owners, thresholds, and salts are operational inputs rather than secrets.

```json
{
  "threshold": 2,
  "saltNonce": "0x0",
  "owners": ["0x...", "0x..."]
}
```

The script validates:

- owners are non-empty and unique
- threshold is between `1` and `owners.length`

## Notes

- `--chain-id` is required.
- The script resolves the RPC with the existing `NODE_URL_<chainId>` and `CUSTOM_NODE_URL` helpers used elsewhere in the repo.
- If the Safe is already deployed, the script verifies owners and threshold against config and exits without writing a new broadcast artifact.
- Chains missing from the `safe-deployments` registry bundled with `@safe-global/protocol-kit` (e.g. Arc, 5042) fail with `Invalid multiSend contract address`. For those, pass `--use-canonical-infra` to resolve addresses from `canonicalSafeInfraAddresses.json` instead. That file pins the canonical Safe v1.4.1 addresses with the `SafeL2` singleton — protocol-kit's default on non-mainnet chains — so the deployment calldata and deterministic address match the existing L2 Safes (`0xd396CcB6…`, vs mainnet's L1-singleton Safe at `0x4c45F70B…`). The script requires every address in the file to have code on the target chain; also verify the bytecode matches mainnet before first use (e.g. compare `cast keccak $(cast code <addr>)` across chains).
