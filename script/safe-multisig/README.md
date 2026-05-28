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

The script only includes a chain when at least one of these is deployed on it:

- a `CounterfactualDepositFactory` (or `CounterfactualDepositFactoryTron`) entry in `broadcast/deployed-addresses.json`
- a `Universal_SpokePool` (presence of `broadcast/DeployUniversalSpokePool.s.sol/<chainId>/` or the Tron variant)
- a sponsored mintburn deployment (any of `SponsoredCCTPSrcPeriphery`, `SponsoredCctpSrcPeriphery`, `SponsoredCCTPDstPeriphery`, `SponsoredOFTSrcPeriphery`, `DstOFTHandler`)

Testnets (every chain ID in `TESTNET_CHAIN_IDs`), Scroll, and Solana are always excluded, even if they qualify above.

"Ops multisig" refers to the chain's new operations Safe (the address from `broadcast/DeploySafe.s.sol/<chainId>/run-latest.json`). The output starts with an overall **Migration progress** percentage = `(Ops multisig cells) / (Ops multisig cells + red cells)` across the ownership/admin columns. The `Ops Multisig Deployed` column is excluded from the count (it tracks Safe deployment, not ownership transfer).

For each qualifying chain the table reports:

1. **Ops Multisig Deployed** — whether the chain has a Safe broadcast in `broadcast/DeploySafe.s.sol/<chainId>/`.
2. **Universal SpokePool Owner** — the on-chain `owner()` of the chain's `Universal_SpokePool` (if any).
3. **Counterfactual WithdrawManager Owner / directWithdrawer** — the on-chain `AdminWithdrawManager.owner()` and `AdminWithdrawManager.directWithdrawer()`.
4. **Sponsored CCTP / OFT Periphery Owner** — the on-chain `owner()` of the Ownable sponsored mintburn peripheries (`SponsoredCCTPSrcPeriphery`, `SponsoredOFTSrcPeriphery`). The Dst variants use `AccessControl` and are not included.
5. **DonationBox Admin** — who holds `DEFAULT_ADMIN_ROLE` on every deployed `DonationBox` variant on the chain (`DonationBox`, `DonationBox_CCTP`, `DonationBox_OFT`). The script calls `hasRole(DEFAULT_ADMIN_ROLE, …)` against the Safe, the chain's legacy multisig, and the fallback EOA so it can attribute the holder.

Cell content:

- green **Ops multisig** — the Safe is the owner / admin (migration complete for this cell).
- red **Legacy multisig** — the chain's pre-migration multisig is still the owner (per-chain entry in `script/mintburn/prod-readiness-multisigs.json`).
- red **fallbackEOA** — the shared fallback EOA from the same config is the owner.
- red `0xABCD…WXYZ` — some other address is the owner (abbreviated to first 4 / last 4 hex chars).
- red **No** — boolean-style checks (`Ops Multisig Deployed`, `DonationBox Admin`) when no candidate matches.
- `—` — not applicable (contract not deployed on the chain, or no Ops multisig deployed yet to compare against).
- `?` — the on-chain call for that cell failed after retries; full error details are in the **Errors from last run** section directly below the table.

RPC env vars (`NODE_URL_<chainId>` or `CUSTOM_NODE_URL`) drive the on-chain checks; chains without an RPC fall back to `PUBLIC_NETWORKS[chainId].publicRPC`. Non-EVM chains (Tron, Solana) skip the RPC checks and show `—`.

Each on-chain call is retried up to **2 times on failure** (3 total attempts) with a short linear backoff (300ms, 600ms). Retries are logged to stderr; only a final, post-retry failure is surfaced in the **Errors from last run** section.

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
