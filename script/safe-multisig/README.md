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

The output starts with an overall **Migration progress** percentage = `Yes / (Yes + No)` across every cell in the migration columns (Safe Deployed is included, so a missing Safe also counts against progress).

For each qualifying chain it reports `Yes` / `No` / `—` (green/red text via GitHub-rendered LaTeX) for:

1. **Safe Deployed** — whether the chain has a Safe broadcast in `broadcast/DeploySafe.s.sol/<chainId>/`.
2. **Safe owns Universal Spoke Pool** — for `Universal_SpokePool` proxies, whether `owner()` matches the chain's Safe.
3. **Counterfactual WithdrawManager owner / directWithdrawer** — whether the on-chain `AdminWithdrawManager.owner()` and `AdminWithdrawManager.directWithdrawer()` match the Safe.
4. **Sponsored CCTP / OFT Periphery owner** — whether the chain's Ownable sponsored mintburn peripheries (`SponsoredCCTPSrcPeriphery`, `SponsoredOFTSrcPeriphery`) are owned by the Safe. The Dst variants use `AccessControl` and are not included.
5. **DonationBox admin** — whether the Safe holds `DEFAULT_ADMIN_ROLE` on every deployed `DonationBox` variant on the chain (`DonationBox`, `DonationBox_CCTP`, `DonationBox_OFT`). DonationBox uses `AccessControl`, so the check is `hasRole(DEFAULT_ADMIN_ROLE, safe)` rather than `owner()`.

`—` is shown when the relevant contract is not deployed on the chain or when the Safe doesn't exist yet (nothing to migrate to). `?` means the on-chain call for that check failed after retries. Full error details are surfaced in an **Errors from last run** section directly below the table — one row per failing check, with chain ID, chain name, check name, and the underlying error string.

RPC env vars (`NODE_URL_<chainId>` or `CUSTOM_NODE_URL`) drive the on-chain checks; chains without an RPC fall back to `PUBLIC_NETWORKS[chainId].publicRPC`. Non-EVM chains (Tron, Solana) skip the RPC checks and show `—`.

Each on-chain call is retried up to **2 times on failure** (3 total attempts) with a short linear backoff (300ms, 600ms). Retries are logged to stderr so you can see which checks needed a second attempt. Only a final, post-retry failure is recorded as an error and surfaced in the **RPC issues?** column and the **Errors from last run** section.

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
