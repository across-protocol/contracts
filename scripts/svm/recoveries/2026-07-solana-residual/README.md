# Recovery: 13,832.309134 USDC residual on the Solana SpokePool

A single relayer refund leaf returning the untracked USDC residual from the Solana SpokePool
vault to the HubPool, left behind by the 2026-07-17 incident. The leaf contains **no refunds**;
236.090934 USDC is deliberately left in the vault to back the 5 outstanding `ClaimAccount`s.

## The leaf

| Field             | Value                                                 |
| ----------------- | ----------------------------------------------------- |
| `amountToReturn`  | `13832309134` (13,832.309134 USDC)                    |
| `chainId`         | `34268394551451`                                      |
| `mintPublicKey`   | `EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v` (USDC) |
| `refundAmounts`   | `[]`                                                  |
| `refundAddresses` | `[]`                                                  |
| `leafId`          | `0`                                                   |

- `relayerRefundRoot` (single leaf ⇒ root = leaf hash): `0x193c697f126d8a64389e82777d4e5581acf8ea65344cba492459bd3744ef9cfd`
- `poolRebalanceRoot` (single empty leaf, `groupIndex 0`): `0x40825ad81e3fa435712b46bb07a662825789eea437fdfe3e0d57275ad35c6802`

Both roots, the exact hash preimage, and a live-state snapshot are in [`leaf.json`](./leaf.json).
`anchor run verifySolanaResidualRecovery` recomputes the roots with this repo's own hashing code
and re-derives the amount from live chain state.

## Why this amount — provable from chain data

1. **The vault holds 14,068.400068 USDC.** Vault `HYhZwefNFmEm9sXYKkNM4QPMgGQnS9VjC6kgxwrGk3Ru`
   (USDC ATA of the SvmSpoke state PDA `3tzNXZAnJaCVikmENJSnJFAzkAnediKTxH3ot9Hiwnkz`), balance
   `14068400068` at slot `434540333` (2026-07-22, finalized). Deposits and fills are paused.
2. **Bundle accounting for Solana is fully settled at zero.** The pool rebalance leaf executed
   2026-07-22 (mainnet tx `0xafe4fd8a6ce6f3b51b3c954f93750c689b7b0cbd6c45b88a123f9925fa6e515a`)
   carries `runningBalances [0]` after `netSendAmounts [-48,659.409254]`, and that return was
   executed and bridged on Solana (tx `2fE3ZDCJsYUPsjeZ7Emt2tHTHxAvKXLQFz42xHQLirHTtDV6JAwHsRo945n5bJrUYz4y8tFrvt3TH2EHDf5ZDgRv`).
   Cumulatively, every hub-instructed return has been honored: the sum of negative
   `netSendAmounts` over all executed Solana USDC pool leaves — excluding the two abandoned
   incident bundles below — equals the sum of all `TokensBridged` events, **7,816,961.112666**,
   exactly. On-chain `TransferLiability.pending_to_hub_pool = 0`. The vault balance is therefore
   invisible to, and unreachable by, the dataworker.
3. **The only outstanding on-chain claims are the 5 `ClaimAccount`s**, deferred relayer refunds
   from Aug 2025, totalling **236.090934** (addresses and amounts in `leaf.json`). Event
   cross-check: Σ deferred `ExecutedRelayerRefundRoot` amounts (511.777577) − Σ
   `ClaimedRelayerRefund` (275.686643) = 236.090934.
4. **Recoverable = 14,068.400068 − 236.090934 = 13,832.309134.** This value is invariant to
   claims being exercised before execution: a claim reduces the vault and the claim total by the
   same amount. With deposits/fills paused, no other flow can touch the vault except this leaf.
   The verify script enforces both preconditions live: it fails unless deposits and fills are
   still paused, and it nets out any `TransferLiability.pending_to_hub_pool` already queued to
   the hub pool (vault USDC backing a previously executed but not-yet-bridged return is not
   residual).

## Where the residual came from (context)

During the 2026-07-17 incident, two root bundles built on forged deposit events (spoke
`rootBundleId`s 12662/12663; hub executions
`0x86e682e5a7014e3a1de4cd021705b7bf539d49dca530636304651b6d755fb963`,
`0xd56b0540cf27441f40b6f17f07d180a2fe8bd85a28b3ce4bcc2b08e5e7c5fb49`) were executed on the
HubPool but their Solana refund leaves could never execute; the corrected bundle chain inherited
only their carried running balance of exactly **50,000**. The 12 real deposits inside those
bundles' Solana block ranges `[433416232, 433424785]` — deposit ids 113014–113025 — total
**63,811.518504** ([`deposits.csv`](./deposits.csv)), so **63,811.518504 − 50,000 = 13,811.518504**
of real deposit inflow fell out of the books. Identity check on the first corrected bundle
(hub tx `0xdf8d8c2cc888f23fd811252a50c5d9dde6b306bd12ce38d9b71d71964ca3563f`):
`−50,000 − 14,862.365817 + 15,815.270212 = −49,047.095605`, its exact on-chain running balance,
where 14,862.365817 is the sum of deposits 113026–113060 (the skipped ranges) and 15,815.270212
its refund leaf executed on Solana
(`2kPBJ5xdwU5C5ARX2whGX1UvbQ97qGDUhzhAYgjrU5492dxZ7SFvDgwoWEdxmSe7v5yVpgK4hUVDUk83nWuW84LZ`).

The remainder of the residual: four direct SPL transfers into the vault totalling 10.730000
(txs `2rtaQQi7519sB3GggbxcdNkVpLqonqbtkCaLfvR8u8ZC`, `wqhdw8GFSXCTERi1TK3DrgFeo6Hq9ypNMcfk7y1ntAHc`,
`5GzNBfL5aMzyxEaz96S23WzpwLteHiskwSXsj2J8bTrQ`, `4hhNig7mAKnsL5vy2JYEbxRUm67BPJDz3ynQFrNjWMjL`),
ten never-refunded dust/test deposits totalling 5.452003 (ids 1–6, 8, 223, 38869, 38872), and
4.608627 of residual event dust (0.03%), conservatively included in the recovery.

`deposits.csv` resolves every deposit in the affected window (113014–113060): each was either
filled on the destination chain (fill tx listed) or refunded (refund tx listed) — no user funds
are part of this recovery. Repayments owed to the two relayers for fills inside the abandoned
bundles' ranges (`E4bX…3kxC` 63,032.994323, `CBG4…1jUF` 734.833656) were never paid on Solana
and are intentionally **not** encoded in this leaf; they are settled against the recovered funds
as an accounting matter.

## Execution (existing tooling, mainnet)

The Solana-side scripts (steps 2 and 3) read the Anchor provider, which defaults to `localnet`
in this repo's `Anchor.toml` — the `--provider.cluster mainnet` flag (or a mainnet RPC URL) and
`--provider.wallet` are required. `proposeRebalanceToHubPool` is Ethereum-side only and defaults
to mainnet. See each script's header for the full env var list (`MNEMONIC`, `HUB_POOL_ADDRESS`,
`NODE_URL_1`).

```bash
# 0. Verify the leaf, roots, live pause state, and live amount:
anchor run verifySolanaResidualRecovery

# 1. Propose on the HubPool (poster bonds):
MNEMONIC=$MNEMONIC HUB_POOL_ADDRESS=$HUB_POOL_ADDRESS NODE_URL_1=$NODE_URL_1 \
anchor run proposeRebalanceToHubPool -- --netSendAmount 13832309134

# 2. After the liveness window, execute (relays roots to the spoke via CCTP,
#    executes this refund leaf, queues the transfer liability):
MNEMONIC=$MNEMONIC HUB_POOL_ADDRESS=$HUB_POOL_ADDRESS NODE_URL_1=$NODE_URL_1 \
anchor run executeRebalanceToHubPool \
  --provider.cluster mainnet --provider.wallet $SOLANA_PKEY_PATH \
  -- --netSendAmount 13832309134

# 3. Burn the queued liability to the HubPool via CCTP:
MNEMONIC=$MNEMONIC HUB_POOL_ADDRESS=$HUB_POOL_ADDRESS NODE_URL_1=$NODE_URL_1 \
anchor run bridgeLiabilityToHubPool \
  --provider.cluster mainnet --provider.wallet $SOLANA_PKEY_PATH
```

**Coordinate with dataworker/disputer operators before proposing**: an out-of-band root bundle
will be auto-disputed by any disputer that reconstructs bundles from chain events, and only one
pending proposal can exist at a time.

Post-execution check: vault balance = 236.090934 = Σ live `ClaimAccount` amounts.
