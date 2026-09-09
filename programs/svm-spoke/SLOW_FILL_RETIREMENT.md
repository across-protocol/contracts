# SVM slow-fill retirement

## Behavior and upgrade compatibility

Solana does not support slow fills. `request_slow_fill` and `execute_slow_relay_leaf` are absent from the program's
dispatch table, public IDL and generated clients. Their historical raw discriminators fail with Anchor's
`InstructionFallbackNotFound` (101), before account validation. A relayed slow root cannot authorize token delivery.
Legacy fast fills, relayer refunds and [V5 deposits/fills](V5_ADAPTER_SPEC.md) retain their existing behavior.

The serialized `FillStatus` slots remain `Unfilled = 0`, `RequestedSlowFill = 1`, `Filled = 2`. Slot 1 is retained
for pre-upgrade accounts; no supported instruction creates that status. An existing requested relay may receive a
normal legacy fast fill before its fill deadline, subject to the usual pause, exclusivity, relay-hash and token
checks. Success transfers the original output amount, writes `Filled`, records the submitting relayer as rent
recipient, and emits `FilledRelay` with `ReplacedSlowFill`. Replay fails with `RelayFilled`. Any transaction failure
rolls back the token transfer and status change. Expired requests remain eligible for ordinary `close_fill_pda`
cleanup to their recorded rent recipient; they cannot be filled after expiry.

An unfilled expired deposit is handled by the normal dataworker-driven refund process on its origin chain;
there is no destination slow-fill fallback. Closing the fill-status PDA only reclaims rent and does not refund
the deposit. `scripts/svm/closeRelayerPdas.ts` discovers accounts from `FilledRelay` events only, so it does not
find requests that were never filled. Those accounts require separate discovery and a `close_fill_pda` call
by their recorded rent recipient after expiry.

V5-tagged relays still require the V5 adapter and transition from an uninitialized PDA directly to `Filled`.
Retiring slow fills does not change the V5 delivery or payer rules.

Historical `RequestedSlowFill` events remain decodable. `FillType` keeps `FastFill = 0`, `ReplacedSlowFill = 1`,
and `SlowFill = 2`; the last variant is historical only. Old slow-fill error slots are retained so subsequent
error numbers do not shift. Indexers must continue checking transaction success before accepting any event.

`RootBundle` retains both roots and its refund-claim bitmap. `relay_root_bundle` and its cross-chain admin payload
still accept both `relayer_refund_root` and `slow_relay_root`; the latter is stored and emitted but cannot be executed.
HubPool forwards the same global slow-relay root to every destination. A nonzero root may contain slow fills for
other chains, so rejecting it on Solana would also block delivery of the accompanying refund root.
No account or admin-message migration is required. Previously prepared slow-fill instruction-parameter buffers
can still be closed by their creator through `close_instruction_params`, which does not require the retired type.

## Lite-chain transition and existing funds

Slow-fill retirement is part of Solana's Lite-chain transition, which removes HubPool LP token rebalancing while
retaining root messaging and refunds. The SDK excludes slow-fill leaves to or from Lite chains and requires
equivalent tokens backed by pool-rebalance routes. Observing an old `RequestedSlowFill` event alone therefore
does not imply that the dataworker will fund a new Solana slow fill. Lite-chain classification uses the deposit's
quote timestamp, so today's classification alone does not prove that older deposits were excluded.

The token-rebalancing restrictions are a separate upgrade change. In the combined deployment, refund leaves
must have `amount_to_return == 0` and `bridge_tokens_to_hub_pool` is removed. Consequently, ordinary
`amount_to_return` processing cannot recover residual Solana vault funds after that upgrade.

Before deploying the combined upgrade, verify the active dataworker/configuration excludes Solana slow fills
and reconcile requests and bundles from before that exclusion, including already-funded slow-fill leaves,
pending return liabilities, and vault balances. Any remaining obligations must be settled before removing
their execution/return paths or handled by a separately reviewed recovery procedure. An origin-chain expiry
refund does not itself return excess Solana vault funds. These are deployment checks; the compatibility tests
do not establish that the live in-flight window is empty.

## Regression coverage

`cargo test -p svm-spoke --lib --features test` checks raw dispatch rejection, serialized status/event compatibility,
the two-root layout and instruction payload, and the shared fill core. CI builds with
`IS_TEST=true yarn build-svm-solana-verify`, generates test IDLs, and runs `anchor test --skip-build`. This exercises the validator
tests in `SvmSpoke.SlowFillRetirement.ts`, ordinary legacy and V5 fills, refund execution, and replay/rollback cases. Use the
Node version in `.github/workflows/pr.yml` and the Anchor/Solana versions resolved from `Cargo.lock`, as CI does.
The genesis fixture `test/svm/accounts/legacy_requested_slow_fill.json` freezes a 45-byte pre-upgrade status account
encoded with the pre-retirement IDL; `test/svm/fixtures/legacySlowFill.ts` defines its deterministic relay and test keys.
This fixture must be loaded when running the slow-fill retirement suite against a manually started validator.
The suite fills and closes the fixture account, so each run requires a fresh validator ledger with the fixture loaded.

Regenerate production IDLs and clients with `yarn generate-svm-artifacts`, then generate target-only test IDLs with
`yarn generate-svm-test-idls`. Keep test instructions out of the package assets. The separate
[real-Gateway lane](../../test/svm-gateway/README.md) exercises the V5 delivery boundary.
