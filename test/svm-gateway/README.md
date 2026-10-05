# SVM V5 real-Gateway conformance

## Reproducible CU comparison

`yarn bench-svm-cu` builds the legacy Spoke at `7445f72de17900544605c7e6706c5fb3b3784738`, this checkout's V5 Spoke,
and the Gateway at `GATEWAY_COMMIT`, then measures five fixed fixtures per flow on fresh Agave 4.1.2 validators.
It needs installed Yarn dependencies, repository history containing that legacy commit, Anchor CLI 0.31.1 and 1.1.2,
and access to the pinned Gateway source. The baseline used Node 22.22.0, Yarn 1.22.22 and `cargo-build-sbf` 4.1.0;
the full tool/runtime metadata is in `cu/baseline.json`. It generates its own IDLs; package clients and local binaries are
not prerequisites. It builds neither Raydium nor planners. Foundry cannot measure SVM compute, so this lane uses the
repository's TypeScript/Agave approach and existing SBF diagnostic guard.

```sh
SVM_SPOKE_ANCHOR="$HOME/.avm/bin/anchor-0.31.1" \
SVM_GATEWAY_ANCHOR="$HOME/.avm/bin/anchor-1.1.2" \
SVM_GATEWAY_CHECKOUT=/path/to/clean/pinned/solana-v5 \
yarn bench-svm-cu
```

Omit `SVM_GATEWAY_CHECKOUT` to clone the private repository with your Git SSH credentials. The checkout must be clean
at the exact pin. Network/dependency access and local validator ports are required. This remains a local benchmark;
the cross-repository credential restriction below also applies here.

Builds pin platform-tools v1.44 for legacy, v1.52 for V5 Spoke, and v1.54 for Gateway. Legacy built with v1.52 can emit
oversized fill stack frames despite exiting successfully; the runner rejects stack diagnostics. These are integration
builds with Spoke's `test` feature, not verified production binaries. Compiler differences are part of this comparison.
Builds run sequentially because the SBF tools update a shared Rust toolchain link. `SVM_CU_SBF` selects the
`cargo-build-sbf` executable; `SVM_CU_BUILD_ROOT` relocates the default `target/cu-builds` compiler caches. Programs
are rebuilt on every run, including when caches are present.

The matrix covers legacy deposit/fill, StepDelegate-funded V5 deposit, co-signed external V5 fill, and co-signed
in-place V5 fill followed by a balance requirement and full recipient transfer. Both fill variants start with the
same source/recipient/vault balances and use the same mint, submitter, recipient, amount, state and account order.
Each fixture has deterministic test-only keys, nonce, path salt, quote/deadline and a fixed Spoke test clock.
StepDelegate funding uses a fixed maximum deadline, keeping the Gateway authorization bytes independent of wall time.
Paths and relay identities necessarily differ between fill variants; their buffer/status PDA bumps are reported.
Fixtures also record source, recipient, Spoke vault and Gateway vault ATA bumps (`sourceBump`, `recipientAtaBump`,
`spokeVaultBump`, `vaultBump`). `recipientAtaBump` always describes the final recipient's ATA, including when Spoke
records an in-place fill against the Gateway vault before Gateway performs final delivery.
Both routes approve the Spoke fill delegate and call `transfer_checked`. The in-place route performs a self-transfer,
clears its unconsumed allowance, then checks the floor and transfers in Gateway. Different account validation and PDA derivation costs
also contribute, so a total-CU difference does not isolate the cost of a single command.
Five fixed seeds expose some of that variation but are not a worst-case bound or a statistical production estimate.
The validator's bundled token programs and activated features are part of this baseline; it is not a mainnet CU budget.
Specifically, [Agave 4.1.2 bundles p-token 1.0.0-rc.1](https://github.com/anza-xyz/agave/blob/v4.1.2/program-binaries/src/lib.rs#L19-L24)
at `TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA`. That bundled binary's SHA-256 is
`8190d3f7ceb6cb7a7a8d8924bff89f9f611e15ce1f806f2b6237f3311a98f697`, matching the baseline's executable hash.
The 310-CU approval includes 150 CU for the compute-budget instruction and 160 CU for `ApproveChecked`.
V5 performs more token CPIs than legacy, so this implementation affects the relative comparison as well as absolute CU.
No mainnet token-program dump was captured for this run; equivalence to mainnet at run time was not verified.

The table reports medians of **consumed CU**, not requested limits:

- `execution`: the deposit/fill transaction, including V5 funding and final delivery, plus its compute-budget instruction.
- `approval`: a separate source/relayer approval transaction where required, including its compute-budget instruction.
  V5 vault approvals executed inside the tape are already part of `execution`.
- `buffer`: initialization and all parameter-fragment uploads, each including its compute-budget instruction.
  Successful execution closes the buffer; there is no extra successful-path close transaction.
- `total`: the sum for each sample before taking the median. The displayed component medians need not add to it.

All token accounts already exist. Minting, state/clock initialization, balance resets, rent-float provisioning,
ATA creation, rent reclaim and other deployment/setup transactions are excluded. Legacy uses an empty message; V5
uses the required 64-byte witness. Successful delivery, source/vault consumption, fill status and rent accounting are
asserted before a run is accepted. PrefundedAdapter, swaps, signed modifications and Token-2022 are separate workloads.

### Interpreting bump variation and buffer costs

The fixed fixtures are intentionally retained rather than grinding addresses until their bumps are 255. For this
baseline, subtracting 1,500 CU per additional PDA search attempt explains all 25 execution measurements and all 15
buffer measurements exactly. The following is an analytical normalization to fixture-variable bumps of 255, not a
second on-chain measurement, a production estimate, or a model guaranteed to apply after program/runtime changes.
Every recorded bump is already canonical for its seeds; 255 simply means the first derivation attempt succeeds.

| Flow             | Measured execution median | Bump-normalized execution | Bump-normalized total |
| ---------------- | ------------------------: | ------------------------: | --------------------: |
| legacy-deposit   |                    34,707 |                    31,707 |                32,017 |
| legacy-fill      |                    41,021 |                    38,021 |                38,331 |
| v5-deposit       |                    73,516 |                    67,516 |                80,155 |
| v5-external-fill |                    84,582 |                    78,582 |                90,911 |
| v5-inplace-fill  |                    89,793 |                    85,293 |                97,622 |

To reproduce the normalization from each `baseline.json` row, define `d(bump) = 255 - bump` and subtract 1,500 times
the following sum from `execution`:

| Flow             | Extra search attempts                                   |
| ---------------- | ------------------------------------------------------- |
| legacy-deposit   | `d(sourceBump) + d(spokeVaultBump) + d(delegateBump)`   |
| legacy-fill      | `d(statusBump) + d(delegateBump) + d(recipientAtaBump)` |
| v5-deposit       | `d(fundingBump) + 2*d(vaultBump) + d(spokeVaultBump)`   |
| v5-external-fill | `d(statusBump) + 2*d(vaultBump) + d(recipientAtaBump)`  |
| v5-inplace-fill  | `d(statusBump) + 2*d(vaultBump) + d(recipientAtaBump)`  |

State bumps are already 255 in every fixture. Fixed program/submitter authority costs remain included. Normalize
V5 `buffer` by subtracting `1,500 * (1 + bufferWrites) * d(bufferBump)`; approvals remain unchanged. Normalized
totals sum these adjusted components per row.

In this baseline, in-place execution costs 6,711 CU more than external execution after normalization in every
sample. Raw per-fixture gaps also include the recorded vault and status PDA search costs. Compare per-row totals;
independently computed component medians need not add to the total median.

`BUFFER_FRAGMENT_BYTES = 800` in `cu/config.ts` is a conservative, fixed test-helper policy, not a measured production
submitter setting or maximum packet utilization. The 891/1,194/1,364-byte V5 parameter payloads each require two writes;
`bufferFragmentBytes` and `bufferWrites` are recorded per row. Each flow sends initialization plus two separate writes,
so this baseline's entire buffer variation is `12,329 + 4,500 * d(bufferBump)`, not a difference in upload count.
A larger fragment can fit this transaction shape and put the deposit payload into one write; packing initialization
with a write can also reduce transaction count. Those are separate SDK/backend composition choices tracked in
[sdk #1541](https://github.com/across-protocol/sdk/issues/1541). This benchmark holds the upload policy fixed to expose
program and bump costs; contracts helpers do not define production client composition.

`target/cu-benchmark/results.json` contains per-case values, fixture identities/bumps, source revisions, fixture and
binary/IDL hashes, compiler pins, validator version/feature-set and SPL Token/ATA executable hashes. Raw receipts and
build/validator logs are alongside it; temporary source builds and ledgers are retained at the printed path.
`SVM_CU_OUTPUT` relocates the output. A run fails if legacy and V5 runtime/program environments differ.
The fixture hash includes the shared `scripts/svm/localValidator.ts` helper as well as the runner, configuration,
measurement code and wire encoders.

The checked-in `cu/baseline.json` is a reviewable snapshot. Normal runs print total-CU deltas and do not modify it or
enforce a regression threshold. After reviewing the provenance and changes, regenerate it explicitly with
`yarn bench-svm-cu --update-baseline` (using the same environment above). To verify reproducibility, run twice into
different `SVM_CU_OUTPUT` directories and compare `measurements` and program/runtime hashes. Transaction signatures,
slots and temporary paths in raw receipts naturally vary. Before committing an updated snapshot, run
`yarn prettier --write test/svm-gateway/cu/baseline.json`.

For the validated-vault optimization's per-fixture CU comparison, see
[PR #1575](https://github.com/across-protocol/contracts/pull/1575)
([issue #1570](https://github.com/across-protocol/contracts/issues/1570)). Reusing the validated vault removes one
vault ATA derivation from self-transfer fills; remaining derivations still contribute address-dependent costs.

## Conformance suite

Run `yarn test-svm-gateway`. It builds Gateway, PrefundedAdapter and AuthorityRequirementPlanner from `GATEWAY_COMMIT` in
`wire.ts` (re-exported by `reference.ts`), builds this checkout's SpokePool with `--features test`, generates test IDLs, and starts
an isolated validator with those programs, SpokePool and Raydium CPMM loaded as upgradeable programs.
It does not clone mainnet state.
The ordinary `test/svm` suite still uses `mock_gateway` at the same program address, so these suites must use separate
validators. Logs and the temporary ledger are retained in the printed temporary directory; the validator is stopped
after the run. Production package IDLs and clients are not regenerated.
Generate production Spoke artifacts first (`yarn generate-svm-artifacts`); the shared wire helpers use its public
generated codecs. CI runs the vector checks after downloading those artifacts.

Install Agave 4.1.2, Anchor CLI 1.1.2 for foreign builds, and Anchor CLI 0.31.1 for this repository's IDL. The runner
pins SpokePool compilation to Solana platform-tools v1.52 rather than the CLI's moving default. With both
versions installed by AVM, for example:

```sh
SVM_GATEWAY_ANCHOR="$HOME/.avm/bin/anchor-1.1.2" \
SVM_SPOKE_ANCHOR="$HOME/.avm/bin/anchor-0.31.1" \
yarn test-svm-gateway
```

Both runners use `scripts/svm/localValidator.ts` for clean pinned checkouts, local ports, validator startup and cleanup.
Gateway clones use SSH; `SVM_GATEWAY_CHECKOUT` avoids cloning when a clean checkout at the exact pin is available.
Readiness requires a confirmed slot above 10, with bounded RPC requests. The validator is stopped and signal listeners
are removed on startup failure and after the test callback, including failures. The focused helper tests run with
`NODE_OPTIONS=--no-experimental-strip-types yarn ts-mocha -p tsconfig.test.json -t 15000 test/svm/Scripts.LocalValidator.ts`.

Builds still run with existing checkouts; arbitrary prebuilt binaries are not accepted as conformance evidence.
Dependency downloads and local validator ports require network permission in sandboxed environments.
Pass Mocha filters through the runner, e.g. `yarn test-svm-gateway --grep 'JIT Raydium'`, for focused validation.

The current runner needs access to the pinned `solana-v5` checkout, so run this lane locally with existing repository
access; do not add a cross-repository credential to `contracts` CI. Ordinary PR checks run
`yarn test-svm-gateway-vectors` for the public-only wire/hash fixtures, but do not run the real-Gateway lane.
Changes in `test/svm-gateway` also trigger the ordinary SVM tests.

Public artifact distribution is a separate follow-up; this lane does not prescribe a hosting repository or require
the development repository to become public. Once matching Gateway/Prefunded binaries and IDLs are publicly
available, adapt the runner to consume an immutable release with reviewed checksums and source/program-ID provenance,
then enable CI without a cross-repository token or approval environment. Rebuilding an immutable public source
snapshot is another option. Until then, the local build remains the conformance path.
Reuse `.github/actions/setup-solana-anchor` to derive this repository's toolchain versions and the `NODE_VERSION`
setting in `pr.yml`. If the Gateway's separate Anchor CLI is downloaded as a release binary, verify it against a
reviewed, pinned SHA-256 checksum (`sha256sum -c`) before execution; a versioned download URL is not an integrity check.

This is a V5 integration test binary, not a verified production release build. Legacy V4 deposit/fill and slow-fill
handlers have been removed (see [historical compatibility](../../programs/svm-spoke/V5_ADAPTER_SPEC.md#historical-compatibility)). The existing
verified-build and ordinary SVM lanes remain separate requirements.

Ordinary Gateway/Prefunded instructions use Anchor builders and IDLs generated from the same pinned checkout as the
binaries. These IDLs stay in the temporary run directory, passed to the suite via `SVM_GATEWAY_IDL_DIR`; no private
artifacts are checked in. `wire.ts` encodes opaque Gateway tape/amount/meta/JIT/buffer payloads, re-exported by `reference.ts`. Spoke deposit/fill
layouts are shared with the mock suites in `test/svm/v5Encoding.ts`; golden-vector derivations remain independent.
All command accounts are committed or explicit injected slots; the outer remaining-account list is only a lookup
pool. Status and payer slots are injected
because their addresses depend on the relay/root or submitter; the adapter derives their expected addresses.
Large committed tapes use the Gateway's content-addressed parameter buffer because lookup tables cannot compress
instruction data. Failed executions leave the buffer available for explicit cleanup.

The [V4-to-V5 coverage inventory](V4_COVERAGE.md) maps every deleted deposit/fill suite guarantee to its replacement,
including guarded Token-2022 funding, native SOL wrapping, vault/ATA provisioning and two external fills in one
transaction. Retired selector, sequential-ID and callback semantics are identified separately.

The suite covers StepDelegate and prefunded source deposits, standard deposit identities and witnesses, external and
in-place destination delivery, first-fill-wins siblings, root mismatch and reuse, account/dispatch rejection, payer
funding/reclaim/withdrawal, and downstream rollback. Deposit and fill approval failures are checked against the SPL
error even when the correct delegate account is supplied. Root reuse examples fund and fully deliver each execution.
Prefunded delivery injects the credit and `PDA(["rent_refund", payer], PrefundedAdapter)`, followed by the payer's
32-byte JIT payload. Tests verify that closing the credit parks its rent in that system-owned PDA and a separate
`claim_rent` transaction signed and paid for by an unrelated claimer refunds the original payer without their signature.
This covers the delivery rent path; PrefundedAdapter's admin `rescue` path has no SpokePool involvement and remains
covered by the upstream suite.

The [adapter spec](../../programs/svm-spoke/V5_ADAPTER_SPEC.md#pda-and-token-invariants) is authoritative for delivery
invariants, the shared-vault trust boundary, and production route enablement. This suite tests those rules; it is not
a production order builder. `canonicalInPlace` approves the fill delegate, executes one fill, clears its unconsumed
self-transfer allowance with a zero approval, then enforces a floor and transfers the full balance. Counterexamples
cover zero/short consumption, multiple fills observing one balance, and actual JIT amounts exceeding committed
minima. `assertAggregateDelivery` checks the observed execution's accounting, not authorization of a root.

`ALLOW_REVERT` is unsupported by this Gateway, so an optional downstream command fails atomically. A separate test
submits an actual failing transaction after the fill and transfer, checks `meta.err`, and proves that fill status,
tokens and payer rent were rolled back. It decodes the attempted `FilledRelay` event from that failed receipt's inner
instructions and matches its deposit ID; such events never count as successful settlement.

The pin includes Gateway's remainder amount form (`bips == 0xB6F2`, resolving to `max(balance - raw, 0)`) and
zero-resolved transfers that skip recipient lookup. Tests cover remainder saturation and a zero full-balance transfer
without a recipient ATA. The positive canonical post-fill floor still rejects an empty vault before that no-op;
a zero floor does not guarantee positive delivery.

The additional `v5_gateway_path.json` vector is a deterministic consumption-tape/hash fixture with placeholder keys,
independently checked by Rust and Solidity as well as TypeScript. Existing `v5_adapter_v1.json` vectors continue to
cover deposit/fill input bytes, dispatch, signature and deposit-ID domains.

## Across fill followed by a destination swap

The destination fixture uses unmodified [Raydium CPMM 0.2.0 source](https://github.com/raydium-io/raydium-cp-swap/tree/244e1241f3c8d90eb93f176dfbc35f2605ec5a5c),
commit `244e1241f3c8d90eb93f176dfbc35f2605ec5a5c`, program `CPMMoo8L3F4NbTegBCKVNunggL7H1ZpdTHKxQB5qKP1C`,
Anchor crates 0.32.1, and Solana platform-tools v1.52. Gateway/PrefundedAdapter remain pinned to
`e2b91eb0454136773728f941b33163346e039aa4`. `SVM_SWAP_CHECKOUT` can reuse a clean checkout at the exact swap pin;
the runner still builds it with its committed Cargo.lock. This proves the pinned source fixture, not equivalence
to a currently deployed mainnet binary or universal Jupiter/DEX compatibility.

The retained [Raydium IDL](fixtures/raydium_cp_swap.244e1241.json) is generated from that same source pin.
Anchor builders construct `initialize` and `swapBaseInput`; the IDL account coder encodes the genesis `AmmConfig`.
Gateway meta flags are derived from the built instruction. Gateway tape and `BalanceSub` encoding remain local;
the fixture checks that the pinned IDL places the first `u64` argument, `amount_in`, after its eight-byte discriminator.
When updating `SWAP_COMMIT`, regenerate the IDL in the matching Raydium checkout with Anchor 0.32.1:

```sh
anchor idl build --program-name raydium_cp_swap --out /tmp/raydium_cp_swap.json -- --locked
```

Copy that output to the versioned fixture and update its import. The complete IDL is retained without hand edits;
ordinary runs use it without invoking Raydium's toolchain selection or adding a Raydium SDK dependency.

Genesis seeds only a local AmmConfig (0.25% trade fee, no other fees) and pool-fee receiver. The real program creates
the pool, deposits equal reserves of two fresh six-decimal SPL mints, and executes `swap_base_input`.
No swap mock, mainnet balances, production keys, or external liquidity is used. The fixture gives the swap signer
SPL delegate authority while the token-account owner remains the distinct Gateway vault authority.

The fixed-route committed tape is `APPROVE(fill delegate) → Spoke ADAPTER_CALL(Fill) → APPROVE(swap delegate) →
CALL(swap_base_input) → BALANCE_REQ(output) → TRANSFER(all output, committed recipient)`.
`BalanceSub` patches the entire live input balance into the swap.
The swap approval replaces the fill's unconsumed allowance in SPL's single delegate slot.
Submitter funding occurs in the same Gateway execution. A lookup table carries the combined program accounts;
the committed tape still uses the content-addressed parameter buffer.

Full-balance approval, `BalanceSub`, and output transfer follow EVM V5 semantics and the same delivery policy:
every recorded fill's actual output must be covered by proportional or authenticated aggregate delivery. This
fixture exercises one funded fill with empty initial vaults; other routes must satisfy the same V5 policy.
See the
[adapter delivery requirements](../../programs/svm-spoke/V5_ADAPTER_SPEC.md#v4-entrypoint-retirement-and-destination-actions).

Tests verify actual pool reserve movement, recipient delivery, cleared input/output vaults and consumed allowance,
plus replay rejection. Swap slippage and an unmet post-swap floor are separately submitted as actual failing
transactions; pool state, reserves, user funding, fill status and payer float must all roll back. The existing
payer reclaim/withdrawal and V5 witness tests remain in the suite.

### JIT swap and signed quality requirement

The auction-shaped fixture commits `APPROVE(fill delegate) → Spoke ADAPTER_CALL(Fill) → APPROVE(fill delegate, 0) →
PLAN_FROM_JIT → BALANCE_REQ(user minimum) → PLAN_FROM_PLANNER(quality) → TRANSFER(all output, committed recipient)`.
Only after the origin deposit commits that
destination path does the fixture build the swap route and sign the quality quote. The JIT child tape contains
`APPROVE → CALL(swap_base_input)`; its own JIT queue is empty. The parent queue supplies three independent items:
the Spoke fill data, the child-plan envelope, and the signed planner envelope.

The parent commits the requirements-only planner, a secp256k1 authority and a plan slot. The authority signs a
child tape containing a stricter output `BALANCE_REQ`; its digest binds the planner domain, Gateway, live path ID,
plan slot and child-tape hash. The real planner verifies the signature and restricts the returned commands to
requirements; Gateway enforces the returned floor before the parent transfers output to the committed recipient.
The signer is generated only for this local fixture. Planner binaries and IDLs come from the same immutable
Gateway checkout, and the program address is read from its generated IDL.

The same committed path rejects swap slippage, an empty swap plan below the user's floor, a valid signed quote
whose quality floor is not met, a modified quote, a weaker quote signed by another key, and signatures for another
path or plan slot. Each failed transaction proves rollback of funding, pool state, fill status and payer rent.
The successful route proves actual reserve movement, both floors, full recipient delivery, consumed delegate
allowance and replay rejection.
This is coverage of one concrete Raydium route and authority policy, not authorization of every possible JIT child
tape. Production builders must apply the same V5 delivery policy to every route they support.

## V4 entrypoint migration and consumer inventory

`deposit`, `deposit_now`, `unsafe_deposit`, and `fill_relay` are absent from Spoke dispatch, IDLs, and generated
clients. Historical selectors fail with `InstructionFallbackNotFound` (101) before argument decoding or account
validation, regardless of message contents or instruction-parameter buffers. All deposits and fills must use
`adapter_execute_across_v5` through authenticated Gateway execution. V5 fills still require the relay witness
`V5_MAGIC_PREFIX || stepId`; destination actions must run as committed Gateway commands following the fill, subject
to the delivery requirements above.

The ordinary SVM suite's [retirement tests](../svm/SvmSpoke.SlowFillRetirement.ts) check removed selectors with empty
and padded payloads, unchanged account/token state on rejection, IDL/client exports, historical event decoding,
and expiry rent reclaim. The [V5 source tests](../svm/SvmSpoke.V5Source.ts) cover authenticated deposits and source
validation; the [V5 fill tests](../svm/SvmSpoke.V5Fill.ts) cover delivery, witness/commitment checks, replay protection,
and downstream rollback. [RealGateway.ts](RealGateway.ts) covers the committed destination swap described above.
The disabled [fake-fill script](../../scripts/svm/fakeFillWithRandomDistribution.ts) exits with a migration message
before creating accounts or sending transactions.

Standalone consumers retained in this repository are `programs/multicall-handler`, its Anchor deployment entries,
`test/svm/MulticallHandler.ts`, public `MulticallHandlerCoder`/`AcrossPlusMessageCoder` exports, the program connector,
and generated MulticallHandler IDLs/clients. Public package consumers outside this repository are not enumerable
here; removing those exports or closing the deployed program is outside this change. Generated artifacts live in
ignored `src/svm/assets` and `src/svm/clients`; regenerate production assets before test-only IDLs.

Follow the [deployment sequence](../../programs/svm-spoke/V5_ADAPTER_SPEC.md#deployment-sequencing) to disable old
routes and reconcile the in-flight window before upgrading. Production cutover requires API and relayer support
for the replacement path and validation of the exact supported swap instruction/version. Owner-bound venues need
their own reviewed staging adapter. The tested JIT route does not enable arbitrary swap programs,
separate-auction prefunded chaining, or aggregate fills.
