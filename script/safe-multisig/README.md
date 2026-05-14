# Safe Multisig

TypeScript helpers for deterministic Safe deployments that still emit Foundry-style broadcast artifacts.

## Files

- `deploySafe.ts` - Deploys a Safe using the committed chain config and writes `broadcast/DeploySafe.s.sol/<chainId>/run-latest.json`
- `config.json` - Global Safe owners, threshold, and salt nonce
- `broadcast.ts` - Foundry-style broadcast writer for the Safe deployment transaction
- `generateMultisigList.ts` - Walks `broadcast/deployed-addresses.json` for chains with a `SpokePool` deployment, looks up each chain's Safe in `broadcast/DeploySafe.s.sol/<chainId>/run-latest.json`, and (via RPC) checks Safe migration status of the SpokePool and `AdminWithdrawManager` owners
- `MULTISIGS.md` - Generated Safe migration status table

## Usage

```bash
yarn ts-node ./script/safe-multisig/deploySafe.ts --chain-id 1
yarn list-multisigs                                # regenerate MULTISIGS.md
yarn list-multisigs -- --output path/to/file.md    # custom output path
```

### What `generateMultisigList.ts` checks

For each chain that has a `SpokePool` entry in `broadcast/deployed-addresses.json`:

1. **Safe address** — read from `broadcast/DeploySafe.s.sol/<chainId>/run-latest.json` if present, otherwise reported as `no Safe deployment`.
2. **SpokePool type** — `Universal` if `broadcast/DeployUniversalSpokePool.s.sol/<chainId>/run-latest.json` (or the Tron variant) exists, otherwise `Native`.
3. **Universal SpokePool owner** — for `Universal_SpokePool` proxies, calls `owner()` on-chain and reports whether it matches the chain's Safe.
4. **AdminWithdrawManager migration** — when an `AdminWithdrawManager` is deployed on the chain, calls `owner()` and `directWithdrawer()` and reports whether each matches the Safe.

RPC env vars (`NODE_URL_<chainId>` or `CUSTOM_NODE_URL`) drive the on-chain checks; chains without an RPC fall back to `PUBLIC_NETWORKS[chainId].publicRPC`. Non-EVM chains (Tron, Solana) skip the RPC checks.

The script always reads `script/safe-multisig/config.json` and loads `MNEMONIC`, `NODE_URL_<chainId>`, and `CUSTOM_NODE_URL` from the repo `.env`.

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
