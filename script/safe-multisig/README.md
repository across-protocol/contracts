# Safe Multisig

TypeScript helpers for deterministic Safe deployments that still emit Foundry-style broadcast artifacts.

## Files

- `deploySafe.ts` - Deploys a Safe using the committed chain config and writes `broadcast/DeploySafe.s.sol/<chainId>/run-latest.json`
- `config.json` - Global Safe owners, threshold, and salt nonce
- `canonicalSafeInfraAddresses.json` - Canonical Safe v1.4.1 contract addresses (SafeL2 singleton) for chains missing from the safe-deployments registry
- `broadcast.ts` - Foundry-style broadcast writer for the Safe deployment transaction

## Usage

```bash
yarn ts-node ./script/safe-multisig/deploySafe.ts --chain-id 1

# For chains not in protocol-kit's safe-deployments registry (e.g. Arc):
yarn ts-node ./script/safe-multisig/deploySafe.ts --chain-id 5042 --use-canonical-infra
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
- Chains missing from the `safe-deployments` registry bundled with `@safe-global/protocol-kit` (e.g. Arc, 5042) fail with `Invalid multiSend contract address`. For those, pass `--use-canonical-infra` to resolve addresses from `canonicalSafeInfraAddresses.json` instead. That file pins the canonical Safe v1.4.1 addresses with the `SafeL2` singleton — protocol-kit's default on non-mainnet chains — so the deployment calldata and deterministic address match the existing L2 Safes (`0xd396CcB6…`, vs mainnet's L1-singleton Safe at `0x4c45F70B…`). The script requires every address in the file to have code on the target chain; also verify the bytecode matches mainnet before first use (e.g. compare `cast keccak $(cast code <addr>)` across chains).
