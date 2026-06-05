# Safe Multisig

TypeScript helpers for deterministic Safe deployments that still emit Foundry-style broadcast artifacts.

## Files

- `deploySafe.ts` - Deploys a Safe using the committed chain config and writes `broadcast/DeploySafe.s.sol/<chainId>/run-latest.json`
- `config.json` - Global Safe owners, threshold, and salt nonce
- `broadcast.ts` - Foundry-style broadcast writer for the Safe deployment transaction

## Usage

```bash
yarn ts-node ./script/safe-multisig/deploySafe.ts --chain-id 1
```

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
