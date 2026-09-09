# SVM SpokePool behavior and upgrade compatibility

## Slow-fill retirement (ACP-221)

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

## Shared SVM upgrade integration

ACP-221 builds above the ACP-184 V5 stack (#1544). CCTP v2 and token-rebalance removal (#1548) remain a separate
branch based on `master`; legacy callback retirement is tracked by ACP-222. The combined audit candidate must include
both ACP-221 and #1548 and verify that refund leaves with nonzero `amount_to_return` are rejected. That refund guard
belongs to #1548 and is not introduced by this branch. The full lite-chain invariant requires both changes.

## Regression coverage

`cargo test -p svm-spoke --lib --features test` checks raw dispatch rejection, serialized status/event compatibility,
the two-root layout and instruction payload, and the shared fill core. CI builds with
`IS_TEST=true yarn build-svm-solana-verify`, generates test IDLs, and runs `anchor test --skip-build`. This exercises the validator
tests in `SvmSpoke.LiteChain.ts`, ordinary legacy and V5 fills, refund execution, and replay/rollback cases. Use the
Node version in `.github/workflows/pr.yml` and the Anchor/Solana versions resolved from `Cargo.lock`, as CI does.
The genesis fixture `test/svm/accounts/legacy_requested_slow_fill.json` freezes a 45-byte pre-upgrade status account
encoded with the pre-retirement IDL; `test/svm/fixtures/legacySlowFill.ts` defines its deterministic relay and test keys.
This fixture must be loaded when running the lite-chain suite against a manually started validator.

Regenerate production IDLs and clients with `yarn generate-svm-artifacts`, then generate target-only test IDLs with
`yarn generate-svm-test-idls`. Keep test instructions out of the package assets. The separate
[real-Gateway lane](../../test/svm-gateway/README.md) exercises the V5 delivery boundary.
