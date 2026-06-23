# Safe Multisig

TypeScript helpers for deterministic Safe deployments that still emit Foundry-style broadcast artifacts.

## Files

- `deploySafe.ts` - Deploys a Safe using the committed chain config and writes `broadcast/DeploySafe.s.sol/<chainId>/run-latest.json`
- `addProposer.ts` - Adds a proposer (Safe Transaction Service "delegate") to a list of Safes across chains, signing each authorization with a Ledger
- `config.json` - Global Safe owners, threshold, and salt nonce
- `proposers.config.json` - Proposer/delegate to add, authorizing owner, label, Ledger HD path, and the per-chain Safe list for `addProposer.ts`
- `canonicalSafeInfraAddresses.json` - Canonical Safe v1.4.1 contract addresses (SafeL2 singleton) for chains missing from the safe-deployments registry
- `broadcast.ts` - Foundry-style broadcast writer for the Safe deployment transaction

## Usage

```bash
yarn ts-node ./script/safe-multisig/deploySafe.ts --chain-id 1

# For chains not in protocol-kit's safe-deployments registry (e.g. Arc):
yarn ts-node ./script/safe-multisig/deploySafe.ts --chain-id 5042 --use-canonical-infra
```

The script always reads `script/safe-multisig/config.json` and loads `MNEMONIC`, `NODE_URL_<chainId>`, and `CUSTOM_NODE_URL` from the repo `.env`.

## Adding proposers (`addProposer.ts`)

A Safe **proposer** (the Transaction Service calls it a "delegate") may only _propose_ transactions to the off-chain Safe Transaction Service on an owner's behalf. It is **not** a signer: it cannot approve or execute, so it can never move funds. Adding one is an off-chain operation — no on-chain transaction and no gas — performed by signing an EIP-712 message and POSTing it to Safe's hosted Transaction Service (`api.safe.global`).

```bash
# Read-only: resolves chains, checks ownership, and reports which Safes already have the proposer
yarn ts-node ./script/safe-multisig/addProposer.ts --dry-run

# Real run: prompts for confirmation, then signs once per chain on the Ledger and POSTs
yarn ts-node ./script/safe-multisig/addProposer.ts
```

Reads `script/safe-multisig/proposers.config.json`:

```json
{
  "delegate": "0x...", // proposer to add
  "delegator": "0x...", // owner authorizing it (signs on the Ledger)
  "label": "Across dev wallet",
  "hdPath": "m/44'/60'/0'/0/0", // Ledger Live default path
  "safes": ["eth:0x...", "arb1:0x..."] // app short-name : Safe address
}
```

How it works, per Safe:

- Resolves `chainId` and the tx-service URL from Safe's **config service** at runtime, so the path segment is always correct even where it differs from the app short-name (`matic` → `.../pol`, `hyper-evm` → `.../hyper`).
- Verifies via the tx-service that `delegator` is an owner of the Safe; skips with a warning if not (override with `--force`).
- Skips Safes where the proposer already exists (idempotent), so re-running is safe.
- Signs the `Delegate(address delegateAddress, uint256 totp)` EIP-712 message with `cast wallet sign --ledger` and verifies the recovered address equals `delegator` **before** POSTing — a wrong derivation path aborts the run instead of authorizing the wrong key.

Flags: `--config`, `--delegate`, `--delegator`, `--label`, `--hd-path`, `--safes a,b,...`, `--dry-run`, `--force`, `--yes`. Set `SAFE_API_KEY` in `.env` to authenticate (optional; unauthenticated is rate-limited to 2 rps / 5k req per month, which is plenty here).

Notes:

- Each chain needs its **own** on-device approval because the signed `chainId` differs — expect one Ledger prompt per Safe.
- If the Ledger rejects the typed-data signature, enable **Blind signing** (or EIP-712 support) in the Ledger Ethereum app settings.
- The config is committed: the proposer address, authorizing owner, and Safe list are operational inputs, not secrets.

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
