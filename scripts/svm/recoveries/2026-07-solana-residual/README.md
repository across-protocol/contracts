# Recovery: direct relayer repayment of refunds stranded on 2026-07-17 (13,832.309134 USDC)

A single relayer refund leaf on the Solana SpokePool paying the relayer repayments stranded
when the 2026-07-17 incident's two poisoned root bundles were abandoned. One of the two
affected relayers (CBG4) was already compensated off-protocol on the incident afternoon —
evidence below — so the leaf pays the full available amount to the other (E4bX). The leaf
has **no `amountToReturn`** — nothing moves to the HubPool — and leaves **236.090934 USDC** in
the vault backing the 5 outstanding `ClaimAccount`s.

## The leaf

| Field             | Value                                                                                          |
| ----------------- | ---------------------------------------------------------------------------------------------- |
| `amountToReturn`  | `0`                                                                                            |
| `chainId`         | `34268394551451`                                                                               |
| `mintPublicKey`   | `EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v` (USDC)                                          |
| `refundAddresses` | `E4bX4nCwe2GcKqt9NpofnXVrCeRp37PAMaiZtV9x3kxC`                                                 |
| `refundAmounts`   | `13832309134` (13,832.309134)                                                                  |
| `leafId`          | `0`                                                                                            |

- `relayerRefundRoot` (single leaf ⇒ root = leaf hash): `0x022285d1b98169fa68340f2415eddd6b23e045b9b72fe62ac188116c31be31a1`
- `poolRebalanceRoot` (single empty leaf, `groupIndex 0`): `0x40825ad81e3fa435712b46bb07a662825789eea437fdfe3e0d57275ad35c6802`
- Alternative two-recipient variant, only if the CBG4 off-protocol compensation below is ever
  unwound (`refundAmounts ["13097475478", "734833656"]`, addresses `[E4bX, CBG4]`): root
  `0xef1fab94e29947c550d5c95f0b59abe56f771c254286ccd1144c44e9ca6cfd95`.

Exact hash preimage and a live-state snapshot are in [`leaf.json`](./leaf.json).
`anchor run verifySolanaResidualRecovery` recomputes the roots with this repo's own hashing code
and re-derives the amounts from live chain state.

## The condition this repayment rests on — provable from chain data

> The relayers made valid fills that were recognised by the protocol but which could not be
> repaid due to the coincidence of the relayer attack.

1. **Valid fills.** 17 fills, each listed in [`stranded_fills.csv`](./stranded_fills.csv) with
   its deposit tx (a real, escrowed deposit: 11 Solana-origin USDC deposits, ids 113014–113025,
   plus 6 Ethereum→Solana deposits, ids 4160927–4161139) and its fill tx (the relayer delivered
   the output to the recipient). Every fill elected `repaymentChainId = 34268394551451`.
   Entitlements: `E4bX…3kxC` **64,153.191307** (12 fills), `CBG4…1jUF` **734.833656** (5 fills).
2. **Recognised by the protocol.** Every one of these fills falls inside the evaluation ranges
   of the two bundles with spoke `rootBundleId`s 12662/12663 (Solana slot ranges
   `[433416232, 433424785]`; each chain's ranges are in the corresponding `ProposedRootBundle`
   events). Both bundles passed the optimistic challenge window and were **executed on the
   HubPool** (txs `0x86e682e5…`, `0xd56b0540…`, 2026-07-17 06:14/06:47 UTC) — the protocol
   accepted the repayment obligations. The validity of these 17 repayments is independent of the
   forged content that poisoned the same bundles: an honest proposer would have included them
   identically.
3. **Could not be repaid.** The two bundles' Solana refund leaves were never executed, and could
   not be: their obligations were computed against ≈36.69M USDC of phantom deposit inflows
   (`netSendAmounts` −36,243,505.321905 and −445,702.471769 that never materialised), far in
   excess of the vault. No `ExecutedRelayerRefundRoot` exists for `rootBundleId` 12662 or 12663.
4. **Never repaid since — exact partition.** Every valid fill electing Solana repayment from
   05:01 UTC through the corrected chain's coverage is either one of the 17 stranded fills or is
   accounted, to the micro-dollar, by the corrective leaf executed at 13:54 UTC (Solana tx
   `2kPBJ5xd…`): for E4bX, 64,153.191307 (stranded) + 13,326.499700 (leaf payment) =
   **77,479.691007** = the sum of all its valid Solana-repayment fills in the window; for CBG4,
   734.833656 + 2,457.730607 = **3,192.564263** likewise. Later Solana leaves paid only two
   expired-deposit refunds (385.686428) and 1.999923 for a fill in their own ranges. LP fees on
   all affected routes are zero (every leaf payment equals a raw sum of fill input amounts), so
   repayment = fill input amount.
5. **The cap, and CBG4's prior compensation.** The stranded entitlement totals 64,888.024963
   (E4bX 64,153.191307 + CBG4 734.833656), but the vault holds only 13,832.309134 above the
   ClaimAccount backing — the balance of the abandoned-window value was already swept to the
   HubPool on 2026-07-22. CBG4 was **already compensated off-protocol**: on 2026-07-17 13:17 UTC
   — 37 minutes before the corrective leaf executed — its Solana USDC account received
   **735.159139 USDC** via a Mayan order of **735.50 USDC sent from Ethereum** (its stranded
   entitlement rounded up, less bridge fees) by `0x837219D7a9C666F5542c4559Bf17D7B804E5c5fe`,
   an Across Council multisig signer (listed in this repo's `script/safe-multisig/config.json`
   and the Across governance docs). Source tx
   `0xed75fc80ac1793e308449f51609162f3f90b73fca09b88d070e004bb3ecfb76e`, Solana delivery
   `2VNwQpsQGnEGLtq6FdXQWs8Qs3zopxK5niQjytXWCr85ZASLm6oyavh6eTSQ5GG3uYd3Gt9BE8dbpXF3gvJ4hxeU`.
   This leaf therefore pays the full available **13,832.309134 to E4bX** (of its 64,153.191307);
   its uncovered 50,320.882173 remains a claim against the HubPool, settled off-chain.

## Why the vault balance is free to pay this

- The vault (`HYhZwef…k3Ru`, USDC ATA of state PDA `3tzNXZ…wnkz`) holds **14,068.400068** (slot
  434540333, finalized); deposits and fills are paused; `TransferLiability = 0`.
- Bundle accounting for Solana is settled at zero: the 2026-07-22 pool leaf (mainnet tx
  `0xafe4fd8a…`) carries `runningBalances [0]`, its return executed and bridged on Solana
  (tx `2fE3ZDCJ…`), and cumulatively Σ hub-instructed returns = Σ `TokensBridged` =
  **7,816,961.112666** exactly (excluding the two abandoned bundles). The residual is invisible
  to the dataworker and will never be swept by it.
- The only on-chain claims are the 5 `ClaimAccount`s totalling **236.090934** (= Σ deferred
  `ExecutedRelayerRefundRoot` amounts 511.777577 − Σ `ClaimedRelayerRefund` 275.686643), left
  untouched. All 5 are USDC-mint claims: each PDA re-derives from the seeds
  `("claim_account", USDC, refundAddress)` with the refund addresses recorded in `leaf.json`
  (recovered from each claim's `initialize_claim_account` tx, also listed there).
  Available = 14,068.400068 −
  236.090934 = **13,832.309134** = Σ `refundAmounts`, and this is invariant to claims being
  exercised before execution. The verify script enforces the preconditions live: it fails
  unless deposits and fills are still paused, nets out any
  `TransferLiability.pending_to_hub_pool` already queued to the hub pool (vault USDC backing a
  previously executed but not-yet-bridged return is not residual), counts only claim accounts
  whose PDA re-derives from the USDC mint, and fails if any claim account outside that set
  exists (a new deferral or another mint's claim — either way the amounts must be re-derived).
- Origin of the residual: the abandoned bundles ingested 63,811.518504 of real deposits
  (ids 113014–113025) into books that were written off wholesale — only their 50,000 carried
  balance survived into the corrected chain. Identity on the first corrected bundle (hub tx
  `0xdf8d8c2c…`): −50,000 − 14,862.365817 (Σ deposits 113026–113060, the skipped ranges) +
  15,815.270212 (its executed refund leaf) = **−49,047.095605**, its exact on-chain running
  balance. Full per-deposit fill/refund resolution: [`deposits.csv`](./deposits.csv).

## Execution (mainnet)

Ethereum-side steps need `MNEMONIC`, `HUB_POOL_ADDRESS` and `NODE_URL_1` (see script headers).
Any Solana-side script use reads the Anchor provider, which defaults to `localnet` in this
repo's `Anchor.toml` — pass `--provider.cluster mainnet` (or a mainnet RPC URL) and
`--provider.wallet`.

```bash
# 0. Verify the leaf, roots, live pause state, and live amounts:
anchor run verifySolanaResidualRecovery

# 1. Propose on the HubPool (Ethereum-side only; proposer posts the standard bond):
MNEMONIC=$MNEMONIC HUB_POOL_ADDRESS=$HUB_POOL_ADDRESS NODE_URL_1=$NODE_URL_1 \
anchor run proposeSolanaResidualRecovery

# 2. After the liveness window: execute the (empty) Solana pool leaf on the HubPool —
#    executeRootBundle(chainId 34268394551451, groupIndex 0, bundleLpFees [],
#    netSendAmounts [], runningBalances [], leafId 0, l1Tokens [], proof []) —
#    which relays both roots to the spoke via CCTP (the executeRebalanceToHubPool.ts flow).

# 3. Re-verify, then execute the refund leaf on Solana. The program's execution path checks
#    only raw vault balance >= refund total (bundle.rs), not the ClaimAccount/liability backing,
#    and the liveness window leaves time for the vault to move (e.g. an old relayed refund leaf
#    executing) — so re-run the live verifier immediately before submitting, and abort if it
#    fails (a relayed root has no execution deadline; nothing forces the leaf through):
anchor run verifySolanaResidualRecovery
#    The leaf is fully funded, so the standard finalizer can execute it once relayed; manual
#    fallback follows the executeRebalanceToHubPool.ts pattern (with --provider.cluster mainnet
#    --provider.wallet $SOLANA_PKEY_PATH), passing the refund address's USDC ATA as a
#    remaining account (printed by verify). No bridge step: amountToReturn = 0.
```

**Coordinate with dataworker/disputer operators before proposing** — an out-of-band root bundle
will be auto-disputed by any disputer that reconstructs bundles from chain events, and only one
pending proposal can exist at a time.

Post-execution check: vault balance = Σ live `ClaimAccount` amounts (this equals 236.090934
only if none of the 5 claims were exercised in the interim — claiming is not pause-gated and
reduces both sides equally); E4bX USDC ATA +13,832.309134.
