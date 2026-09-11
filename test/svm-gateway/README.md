# SVM V5 real-Gateway conformance

Run `yarn test-svm-gateway`. It builds Gateway and PrefundedAdapter from the immutable `GATEWAY_COMMIT` in
`reference.ts`, builds this checkout's SpokePool with `--features test`, generates test IDLs, and starts
an isolated validator with Gateway, PrefundedAdapter, SpokePool and Raydium CPMM loaded as upgradeable programs.
It does not clone mainnet state.
The ordinary `test/svm` suite still uses `mock_gateway` at the same program address, so these suites must use separate
validators. Logs and the temporary ledger are retained in the printed temporary directory; the validator is stopped
after the run. Production package IDLs and clients are not regenerated.

Install Agave 4.1.2, Anchor CLI 1.1.2 for foreign builds, and Anchor CLI 0.31.1 for this repository's IDL. The runner
pins SpokePool compilation to Solana platform-tools v1.52 rather than the CLI's moving default. With both
versions installed by AVM, for example:

```sh
SVM_GATEWAY_ANCHOR="$HOME/.avm/bin/anchor-1.1.2" \
SVM_SPOKE_ANCHOR="$HOME/.avm/bin/anchor-0.31.1" \
yarn test-svm-gateway
```

`SVM_GATEWAY_CHECKOUT` may point to an existing clean checkout at the exact pin to avoid another clone. Builds still
run; arbitrary prebuilt binaries are not accepted as conformance evidence. Dependency downloads and local validator
ports require network permission in sandboxed environments.

The current runner needs access to the pinned `solana-v5` checkout, so run this lane locally with existing repository
access; do not add a cross-repository credential to `contracts` CI. Ordinary PR checks run
`yarn test-svm-gateway-vectors` for the dependency-free wire/hash fixtures, but do not run the real-Gateway lane.
Changes in `test/svm-gateway` also trigger the ordinary SVM tests.

Public artifact distribution is a separate follow-up; this lane does not prescribe a hosting repository or require
the development repository to become public. Once matching Gateway/Prefunded binaries and IDLs are publicly
available, adapt the runner to consume an immutable release with reviewed checksums and source/program-ID provenance,
then enable CI without a cross-repository token or approval environment. Rebuilding an immutable public source
snapshot is another option. Until then, the local build remains the conformance path.
Reuse `.github/actions/setup-solana-anchor` to derive this repository's toolchain versions and the `NODE_VERSION`
setting in `pr.yml`. If the Gateway's separate Anchor CLI is downloaded as a release binary, verify it against a
reviewed, pinned SHA-256 checksum (`sha256sum -c`) before execution; a versioned download URL is not an integrity check.

This is a V5 integration test binary, not a verified production release build. The pinned compiler currently reports
an oversized account-validation stack frame in the legacy `FillRelay` handler;
this lane does not exercise or certify that handler. Slow-fill handlers have been removed (see
[historical compatibility](../../programs/svm-spoke/V5_ADAPTER_SPEC.md#historical-compatibility)). The existing verified-build and ordinary SVM lanes remain
separate requirements.

Ordinary Gateway/Prefunded instructions use Anchor builders and IDLs generated from the same pinned checkout as the
binaries. These IDLs stay in the temporary run directory, passed to the suite via `SVM_GATEWAY_IDL_DIR`; no private
artifacts are checked in. `reference.ts` encodes opaque Gateway tape/amount/meta/JIT/buffer payloads. Spoke deposit/fill
layouts are shared with the mock suites in `test/svm/v5Encoding.ts`; golden-vector derivations remain independent.
All command accounts are committed or explicit injected slots; the outer remaining-account list is only a lookup
pool. Status and payer slots are injected
because their addresses depend on the relay/root or submitter; the adapter derives their expected addresses.
Large committed tapes use the Gateway's content-addressed parameter buffer because lookup tables cannot compress
instruction data. Failed executions leave the buffer available for explicit cleanup.

The suite covers StepDelegate and prefunded source deposits, standard deposit identities and witnesses, external and
in-place destination delivery, first-fill-wins siblings, root mismatch and reuse, account/dispatch rejection, payer
funding/reclaim/withdrawal, and downstream rollback. Root reuse examples fund and fully deliver each execution.

The [adapter spec](../../programs/svm-spoke/V5_ADAPTER_SPEC.md#pda-and-token-invariants) is authoritative for delivery
invariants, the shared-vault trust boundary, and production route enablement. This suite tests those rules; it is not
a production order builder. `canonicalInPlace` exercises the single-fill/floor/full-transfer template. Counterexamples
cover zero/short consumption, multiple fills observing one balance, and actual JIT amounts exceeding committed
minima. `assertAggregateDelivery` checks the observed execution's accounting, not authorization of a root.

`ALLOW_REVERT` is unsupported by this Gateway, so an optional downstream command fails atomically. A separate test
submits an actual failing transaction after the fill and transfer, checks `meta.err`, and proves that fill status,
tokens and payer rent were rolled back. It decodes the attempted `FilledRelay` event from that failed receipt's inner
instructions and matches its deposit ID; such events never count as successful settlement.

The additional `v5_gateway_path.json` vector is a deterministic consumption-tape/hash fixture with placeholder keys,
independently checked by Rust and Solidity as well as TypeScript. Existing `v5_adapter_v1.json` vectors continue to
cover deposit/fill input bytes, dispatch, signature and deposit-ID domains.

## Across fill followed by a destination swap

The destination fixture uses unmodified [Raydium CPMM 0.2.0 source](https://github.com/raydium-io/raydium-cp-swap/tree/244e1241f3c8d90eb93f176dfbc35f2605ec5a5c),
commit `244e1241f3c8d90eb93f176dfbc35f2605ec5a5c`, program `CPMMoo8L3F4NbTegBCKVNunggL7H1ZpdTHKxQB5qKP1C`,
Anchor crates 0.32.1, and Solana platform-tools v1.52. Gateway/PrefundedAdapter remain pinned to
`457cf693d09765c8e7e9ab33d23f84cba0999afe`. `SVM_SWAP_CHECKOUT` can reuse a clean checkout at the exact swap pin;
the runner still builds it with its committed Cargo.lock. This proves the pinned source fixture, not equivalence
to a currently deployed mainnet binary or universal Jupiter/DEX compatibility.

Genesis seeds only a local AmmConfig (0.25% trade fee, no other fees) and pool-fee receiver. The real program creates
the pool, deposits equal reserves of two fresh six-decimal SPL mints, and executes `swap_base_input`.
No swap mock, mainnet balances, production keys, or external liquidity is used. The fixture gives the swap signer
SPL delegate authority while the token-account owner remains the distinct Gateway vault authority.

The committed tape is `Spoke ADAPTER_CALL(Fill) → APPROVE → CALL(swap_base_input) → BALANCE_REQ(output) →
TRANSFER(all output, committed recipient)`. `BalanceSub` patches the entire live input balance into the swap.
Submitter funding occurs in the same Gateway execution. A lookup table carries the combined program accounts;
the committed tape still uses the content-addressed parameter buffer.

Full-balance approval, `BalanceSub`, and output transfer follow EVM V5 semantics and the same delivery policy:
every recorded fill's actual output must be covered by proportional or authenticated aggregate delivery. This
fixture exercises one funded fill with empty initial vaults; other routes must satisfy the same V5 policy.
See the [adapter delivery requirements](../../programs/svm-spoke/V5_ADAPTER_SPEC.md#legacy-callback-retirement-and-destination-actions).

Tests verify actual pool reserve movement, recipient delivery, cleared input/output vaults and consumed allowance,
plus replay rejection. Swap slippage and an unmet post-swap floor are separately submitted as actual failing
transactions; pool state, reserves, user funding, fill status and payer float must all roll back. The existing
payer reclaim/withdrawal and V5 witness tests remain in the suite.

## Callback migration and consumer inventory

Legacy Spoke fills reject nonempty callback payloads explicitly; V5 witnesses remain required by the adapter.
The ordinary SVM suite covers inline and buffered parameters, with malformed and well-formed payloads rejected
identically before parsing. These are two parameter-loading paths, not distinct payload-parsing branches; actual
failed receipts show no handler invocation. `SvmSpoke.Fill.ts` separately pins `V5FillOnly` for V5-prefixed messages.
`fakeFillWithRandomDistribution.ts` now exits with a migration message before creating accounts or sending transactions.

Standalone consumers retained in this repository are `programs/multicall-handler`, its Anchor deployment entries,
`test/svm/MulticallHandler.ts`, public `MulticallHandlerCoder`/`AcrossPlusMessageCoder` exports, the program connector,
and generated MulticallHandler IDLs/clients. Callback rejection tests use the encoders only to construct rejected
inputs. Public package consumers outside this repository are not enumerable here; removing those exports or closing
the deployed program is outside this change. Generated artifacts live in ignored `src/svm/assets` and
`src/svm/clients`; regenerate production assets before test-only IDLs.

Follow the [deployment sequence](../../programs/svm-spoke/V5_ADAPTER_SPEC.md#deployment-sequencing) to disable old
routes and reconcile the in-flight window before upgrading. Production cutover requires API and relayer support
for the replacement path and validation of the exact supported swap instruction/version. Owner-bound venues need
their own reviewed staging adapter. This fixture does not enable
arbitrary JIT swaps, separate-auction prefunded chaining, or aggregate fills.
