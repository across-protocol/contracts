# V5 Spoke CU estimates using mainnet account snapshots

Run `yarn estimate-svm-fork-cu` from the contracts root. This is a local Agave
account-snapshot replay, not a full historical bank fork or a transaction landing
experiment. Mainnet access only reads accounts and deployed IDL data. All
transactions use deterministic test-only keys and a loopback validator.

The [CU and SOL/USD cost study](results/2026-10-12.md) records the
measured ranges, archive cutoff, collection status and binary provenance. Refresh that
snapshot after extending the fee-collection window using the cost-report command
below; a new validator run is needed only when changing the CU workload or its
program/runtime inputs.

## Understanding CU versus priority-fee costs

The generated study separates execution CU into **Spoke**, **Raydium CPMM**, and
**Gateway/other**, alongside Spoke's percentage of total execution CU. The exporter
derives this from confirmed execution logs; the portable evidence includes those
logs and the offline replay command recalculates the attribution. Nested token,
system and event CPIs are included in their caller's consumption. Only outermost
Spoke/Raydium invocations are counted, so self-CPI events are not added twice.
Gateway/other is the residual, including Gateway validation, funding/delivery,
other calls, CPI dispatch and compute-budget overhead. Approval, buffer and
lookup-table setup transactions are outside this execution-only breakdown.

In the pinned study, Spoke contributes about **29k CU to deposits** and **33–42k CU
to fills**, including its nested calls. That is roughly **40–50% of plain execution
CU** and **26–32% with a swap**. Swap→deposit consumes about **1.65×** the execution
CU of a co-signed deposit; Spoke's deposit consumption is unchanged. This is an
attribution of the measured transaction, not a counterfactual estimate of how much
CU removing Spoke would save.

Compare the report's **fixed 50k** network-fee column with its **snapshot ranges**:
the former holds the rate constant to expose differences in transaction work and
signature counts. The large swap-cost tail in the current observations is driven
mainly by higher account-associated priority-rate estimates, rather than a
similarly large increase in CU. The peak-rate/baseline ratio is regenerated from
the fee evidence as the collection window grows. Those estimates are historical
observations, not proven required landing bids.

One priority rate applies to the **whole requested transaction CU limit**, including
the safety margin. A swap-associated rate therefore also prices the Spoke and
Gateway work at that rate. The per-program CU shares do not split the transaction
into separately billed fee markets; base signature fees, rent and auxiliary
transactions remain separate.

## Collector source

The fee collector, Dockerfile, and `examples/svm-fees/spoke-components.json`
are preserved under Jussi tag
[`measurements/svm-fees-2026-10-12`](https://github.com/across-protocol/jussi/tree/measurements/svm-fees-2026-10-12),
pinned to commit [`7962291b881eaa82a8b181b03a3cbb8799652581`](https://github.com/across-protocol/jussi/tree/7962291b881eaa82a8b181b03a3cbb8799652581).
This is standalone measurement tooling maintained on `reinis/svm-fee-measurement`;
it does not depend on merging the collector into production Jussi.

For a fresh sibling checkout from the contracts root:

```sh
git clone --branch measurements/svm-fees-2026-10-12 --single-branch https://github.com/across-protocol/jussi.git ../jussi
git -C ../jussi rev-parse HEAD
```

Verify the commit above, then follow the pinned
[collector run guide](https://github.com/across-protocol/jussi/blob/7962291b881eaa82a8b181b03a3cbb8799652581/docs/svm-fee-measurement.md)
to collect from a clean revision. Keep the tag fixed; collector changes should
receive a new tag and commit pin so existing archives stay reproducible.

## Programs and artifacts

The default lane **downloads Spoke; no local build is needed**. It uses
[`v6.0.0-beta.3`](https://github.com/across-protocol/contracts/releases/tag/v6.0.0-beta.3):
the production `.so` from the GitHub release archive and the production IDL from
the exact-version npm package. [spoke-release.json](spoke-release.json) pins the
release commit, successful build run, archive URLs, archive SHA-256 hashes and
extracted binary/IDL hashes. Downloads never follow `latest` or the npm `beta` tag.
Only the required archive members are extracted, directly into the run directory.

The runner rejects differences in program sources, Cargo dependencies, Anchor
config, verified-build recipe or build helpers relative to the release commit.
It fetches that commit from the public contracts repository if missing locally.
If the sources or build inputs change, publish a matching release and update the
complete release pin before measuring. There is no local-build or CI-artifact fallback.

Beta.3's production binary and IDL exactly match the artifacts used in the existing
study (source `7df8c6fd445b4ec7fd74f6d1d983e5378139c3d4`, CI run `37975260687`).
Those historical measurement records remain unchanged; no CU rerun is needed.
The measured Spoke is prospective V5 code; the paused deployed Spoke is not used.

Gateway, SPL Token, Associated Token, Raydium CPMM executables, Gateway config,
Spoke state, mints, shared vaults, and pool state come from mainnet. Mutable pool
accounts and program bytes are captured in one finalized `getMultipleAccounts`
response. The Gateway IDL comes from its on-chain IDL account. Mainnet feature
accounts are captured separately; those and the IDL do not have the same atomic
bank context. Executable hashes are checked again on the local validator.

## Run

Use Node 22, installed locked Yarn dependencies, Agave 4.1.2, Git, curl and tar.
The first run needs public GitHub/npm downloads and a mainnet RPC; GitHub CLI
authentication and existing `target/deploy` binaries are unnecessary. `SVM_FEE_RPC_URL` is the
same secret environment variable used by the fee collector; it is never written
to the output.

```sh
SVM_FORK_FEE_MANIFEST=../jussi/examples/svm-fees/spoke-components.json yarn estimate-svm-fork-cu
```

`SVM_FORK_OUTPUT` must be a new directory (default `target/fork-cu-<timestamp>`).
`SVM_FORK_SAMPLES` defaults to 3, accepts 1–10, and starts a fresh validator and
restores the same pool snapshot for each deterministic payer/recipient sample.
Flow order within a sample is fixed; swaps change the pool for the next flow.
These samples expose address/PDA variation, not a statistical worst-case bound.
Set `SVM_FORK_FLOWS` to a comma-separated selection of `deposit-cosigned`,
`deposit-step-delegate`, `fill-external`, `fill-inplace`, `swap-deposit`,
`fill-swap`, and `fill-jit-swap` to run only those flows in the specified order.

A saved mainnet account snapshot can be reused without fetching mainnet again.
The runner still downloads and verifies the pinned release artifacts:

```sh
SVM_FORK_SNAPSHOT=/absolute/previous/run/mainnet-snapshot.json SVM_FORK_OUTPUT=/absolute/new/run yarn estimate-svm-fork-cu
```

Each run records the release tag, commit, download URLs and hashes in
`spoke-artifact.json`, which is also included in the measurement provenance.
No production signing keys or Docker service are needed. Recalculating the
published cost report from portable evidence remains entirely offline and
does not use binary artifacts.

## Matrix and measurement

The seven flows are USDC co-signed deposit, USDC StepDelegate deposit (including a
separate approval), external USDC fill, in-place USDC fill plus final delivery,
WSOL→USDC CPMM swap then deposit, USDC fill then committed CPMM swap to WSOL, and
USDC fill then a JIT swap plan with a committed output floor and final delivery.
The JIT case does not include an authority-signed quality planner. PrefundedAdapter,
native SOL wrapping/closing, new recipient ATAs, Token-2022, aggregated fills,
signed deposit modifications, and other DEXes are separate workloads.

The fixture uses the same key for source owner and submitter, including in
co-signed funding mode. A distinct sponsor adds another signature and its base
fee. Swap minimum output and swap-deposit committed amounts use one base unit to
isolate execution cost; these are fixture thresholds, not production quotes or
slippage settings.

Each transaction is first simulated with a 1.4M CU ceiling, then submitted with
`ceil(simulated CU * (1 + marginBps / 10000))`. The default `SVM_FORK_MARGIN_BPS` is
1000 (10%), following the [Solana compute-budget example](https://solana.com/developers/cookbook/transactions/optimize-compute).
The lane rejects an oversized padded limit rather than silently capping it. It
records both simulated and actually consumed CU and requires successful receipts
within the submitted limit. The margin is a configurable policy, not a landing or
worst-case guarantee. The local priority rate is zero; mainnet priority costs must
be calculated from the **submitted CU limit**, separately for each transaction.

Execution, separate approval, parameter-buffer initialization, and every 800-byte
buffer upload are recorded individually. Their sum is the per-flow consumed CU,
not one transaction's fee budget. Successful execution closes the buffer. Lookup
table creation/extensions are recorded separately as setup; the workload assumes
reusable tables and existing source/recipient token accounts. Their creation costs
must be included if your submitter creates these per order. Each serialized v0
transaction must fit 1232 bytes.

The lane asserts source consumption, cleared Gateway vaults/allowances, actual
recipient or Spoke-vault balance changes, fill status, fill-rent accounting, buffer
closure, and pool reserve movement for swaps. Failed runs do not write a completed
`results.json`.

## Snapshot adaptations and limits

`mainnet-snapshot.json` remains intact. Separate genesis files and `patches-N.json`
record all account-data adaptations:

- Clear only the Spoke state's two pause flags. Retain its owner, seed zero,
  chain ID and other configuration. No mainnet unpause transaction is sent.
- Normalize upgradeable ProgramData deployment slots to local genesis so the
  local program cache can load them. Executable bytes and upgrade authorities
  remain unchanged.
- Give synthetic payers/source ATAs test inventory, provision recipient ATAs and
  fill-rent floats, empty Gateway vaults/allowances, and create absent Spoke ATAs.
  These are setup changes, not measured production account creation.

Genesis account `rentEpoch` is normalized to zero (RPC JavaScript numbers cannot
preserve the u64 maximum precisely). Token account native reserves and lamports
remain consistent. The validator uses its local Clock; quote/deadline values are
read from that Clock. Snapshot slots, timestamps, original bytes, patches, binary
hashes, build recipe, IDLs and fixture hashes are retained.

Features known to local genesis but absent from the mainnet active set are
explicitly deactivated. Both the known active intersection and mainnet feature IDs
absent from local genesis are reported. The latter can include retired features;
this is not proof of complete runtime parity. Agave version, runtime behavior and
future activation/program upgrades can change CU. These measurements are for the
recorded program/state/runtime combination, not exact future mainnet guarantees.

## Pairing with Jussi

The default CPMM pool is `47hq28mcL7q5GhBg7epyGF2dnuJd4MKFt8QhT7CzYUp4`, the
USDC/WSOL pool in Jussi's `swap-raydium-cpmm-usdc-wsol-47hq28` component. It is a
small-liquidity pool, not a generic Raydium congestion proxy; CLMM is different.

`fee-inputs.json` includes every transaction's CU limit, signatures, full resolved
writable account set (including lookup-table keys), matching collector components,
and uncovered addresses. Only components entirely contained in the actual
writable set match. Synthetic submitter/source/recipient addresses and per-order
buffer/status accounts will generally be uncovered; historical production payer
components are not substituted automatically. Review them before applying a
shared-account rate. Combine matching components' raw rates by slot, as the Jussi
collector report does, before deriving an estimate. Missing coverage is not zero.

Outputs: `results.json`, `sample-N.json`, `receipts-N.jsonl`, `fee-inputs.json`,
`provenance.json`, `spoke-artifact.json`, raw snapshot, genesis patches, release archives,
IDLs/binaries, and validator logs/ledgers. Ledgers are retained for debugging.

Focused boundary checks:

```sh
NODE_OPTIONS=--no-experimental-strip-types yarn ts-mocha -p tsconfig.json test/svm-gateway/fork/Estimator.ts
```

## Verify and reproduce the published study

The portable evidence is sufficient to regenerate the complete published report:

```sh
yarn replay-svm-fork-costs test/svm-gateway/fork/results/2026-10-12-fee-evidence.json test/svm-gateway/fork/results/2026-10-12.md --check
```

Omit `--check` to write the report. The same command accepts `.json.gz` evidence.
It accepts the schema-3 evidence produced by the exporter below and needs only
the checkout and locked Node dependencies, without local receipts,
an RPC connection, a validator or the raw collector archive. It independently
recalculates execution CU attribution, costs, missing-data counts, rates and percentiles, checks the stored
summaries and raw extrema witnesses, and verifies the document including its
evidence hashes. Measurement provenance and interpretation are embedded in the
evidence, so there is no hand-assembled report header. CI runs this check through
`test-svm-gateway-vectors`. Exporter/replay source hashes identify the code used
for the historical export; they are provenance, not a requirement that the current
tools remain byte-identical. After a renderer change, regenerate the Markdown from
the committed evidence without re-exporting the raw archive.
Replay requires at least one raw witness at each flow's cost-eligible minimum and
maximum execution rate, global rate and SOL/USD price. Ties need only one witness;
missing fee/price observations cannot satisfy the corresponding extrema check.
Selected witnesses still cannot prove completeness of the full raw archive.

## Recalculate SOL/USD costs from a growing Jussi archive

`yarn report-svm-fork-costs` prices the saved CU results offline. No validator,
Docker restart, mainnet RPC, or new CU measurement is needed. Use Node 22:

```sh
yarn report-svm-fork-costs <CU-run-directory> <snapshots.jsonl> <new-output-directory>
```

Choose a new output directory each time. Repeating the command with the growing
archive includes the additional snapshots. It writes `costs.md`, `costs.json`,
and `fee-evidence.json` (or `fee-evidence.json.gz` above 1 MB of compact JSON). The portable evidence includes execution signatures, logs and per-program CU attribution. The full JSON includes per-transaction baseline fees, CU sample IDs and timestamps
for extrema, component sets, missing-data counts, prices, and input hashes.

Copy the generated evidence to the study's existing `<date>-fee-evidence.json`
path (or `.json.gz`), then run `replay-svm-fork-costs` with that path and the
existing `<date>.md` path to regenerate the report. Commit both files together.
If compression changes the extension, remove the superseded evidence file and
use the new extension in the command. Keep one study and evidence artifact;
do not create a full dated copy for each refresh or downsample away brief spikes.
The generated report records whether collection had ended at its cutoff.
Above 1 MB,
the reporter automatically uses gzip compression with a normalized OS header.
Deflate output can vary between zlib versions, so the uncompressed JSON SHA-256
(`jsonSha256`) is the reference for comparing regenerated evidence. Keep the generated
bytes unchanged: these files are excluded from Prettier, and the report records
both the JSON reference hash and the exact artifact SHA-256 and byte lengths.
`costs.json.evidenceArtifact` records the filename, both hashes, artifact bytes
and original JSON bytes. For compressed files, hash the output of `gzip -dc`
to check the JSON reference; hash the file itself to check artifact integrity.

The portable artifact contains the exact account sets, all derived per-cycle fee
rates and matching prices/base fees, CU/signature/rent inputs, PDA bump
metadata, shared lookup-table addresses, measurement provenance and full raw
RPC windows at the rate/cost/price extrema. `columns` describes each compact row;
`series` and `flows` map execution rates to components. Rates are micro-lamports/CU.
`null` means missing, not zero. Paths, RPC endpoints and credentials are excluded.

Reviewers can recalculate the tables without the local archive and inspect how
extreme rates were derived. Selected raw witnesses do not independently prove
that no larger value existed elsewhere in the full archive; the prefix hash
identifies that full source. For compressed evidence, use `gzip -dc <file>`.

The report freezes the archive's byte length at startup and processes complete
newline-terminated records within that prefix, so the collector can keep running.
It records the prefix byte count and SHA-256. To reproduce a previous cutoff, set
`SVM_COST_ARCHIVE_BYTES` to its `archive.bytes` value. Invalid complete records
fail; a trailing partial record is reported and excluded.

Two scenarios are calculated:

- **Fixed baseline:** 50,000 micro-lamports/CU on every transaction, using the latest
  valid archived base fee and SOL/USD quote. The range reflects the three measured
  CU fixtures. This is a fixed rate, not a floor added to the snapshot scenario.
- **Observed range:** global plus matched shared-account components for execution;
  global alone for approval, buffer, and optional lookup-table setup transactions.
  Intersect raw component slots, take their maximum per slot, select the latest
  25 slots, drop zero rates, and take the integer mean, matching Jussi's estimator.
  Entirely zero windows estimate zero; missing/failed components are excluded,
  counted, and never substituted with zero. The min/max spans successful archive
  observations and CU fixtures. Each USD observation uses the price from the same
  snapshot, subject to the collector's recorded maximum price age.

The fee for each transaction is:

```text
base fee per signature × signature count
  + ceil(submitted CU limit × micro-lamports per CU / 1,000,000)
```

Sum transaction fees, then divide lamports by 1,000,000,000 for SOL and multiply by
SOL/USD. This follows the [Solana fee formula](https://solana.com/docs/core/fees).
The report uses archived mainnet base fees: the local validator's fee governor can
produce different fees, so its receipt fee is not used as the production base fee.
The already-padded submitted limits are used without applying another CU margin.

**Fees and rent are separate.** Receipt balance changes identify parameter-buffer
rent (fully returned during successful execution), new fill-status rent (locked
until closure after the fill deadline), and lookup-table rent. The primary fee
scenario assumes existing ATAs and reusable lookup tables. Separate totals add
retained fill-status rent, or fresh lookup-table setup fees plus retained rent.
Temporary buffer deposits are listed as capital requirements, not added again to
net cost. A prefunded fill-rent float is also capital, not an additional per-fill
fee. Later account-close transactions are outside the measured matrix.

These are on-chain SOL fees and rent allocations. Transferred principal, swap
trading fees/slippage, external tips, retries, new ATA/native-SOL setup and other
unmeasured operations are excluded. A historical estimator maximum is not a bound
on future fees or evidence of the minimum bid needed to land. The sampled Raydium
pool does not represent every swap route.

Cost-accounting tests:

```sh
NODE_OPTIONS=--no-experimental-strip-types yarn ts-mocha -p tsconfig.json test/svm-gateway/fork/Costs.ts
```

## CU variation and transaction layout

The reusable lookup table holds shared programs, mints, vaults, state, delegates
and pool accounts. Parameter buffers, fill-status PDAs, StepDelegate funding PDAs,
source/recipient ATAs and the submitter's fill payer remain static keys. The actual
submitted transaction uses this layout; `transactions[].bytes` records its packet
size and the runner enforces 1232 bytes. Fresh-table fees/rent use this same table.

CU extrema are the lowest/highest **observed** values, not production constants.
PDA bump searches explain an important source of seed-dependent variation:

| Account          | Seed variation               | Search phases                                                                       |
| ---------------- | ---------------------------- | ----------------------------------------------------------------------------------- |
| `execute_params` | submitter and parameter hash | buffer initialization and each write; execution verifies the stored bump            |
| `step_funding`   | step, mint and deadline      | StepDelegate deposit execution                                                      |
| `fills`          | relay hash                   | fill execution                                                                      |
| `v5_fill_payer`  | submitter                    | fill execution; varies across sampled wallets                                       |
| Recipient ATA    | recipient and mint           | Spoke external-fill validation, or Gateway terminal transfer in in-place/swap fills |

`rows[].pdaSearches` records bumps and `255 - bump` extra candidate attempts for
the order-, submitter- and recipient-dependent accounts, including external-fill
recipient validation. It is not a syscall trace or an inventory of shared PDAs,
whose seeds remain fixed in this study. The evidence also derives
`fixtures[].tokenAccountPdas` from confirmed token-balance metadata and resolved
account keys. Presence in that broader ATA inventory does not mean every program
searches that ATA; use the phase table above.

The observed execution-CU differences are exactly 1,500 times the difference in
summed execution-phase `extraAttempts`. Three fixtures do not characterize the
tail. For random seeds, model each candidate as off-curve with probability about
one half: `P(extraAttempts >= k) ≈ 2^-k`. At least eight extra attempts occur
about 0.39% of the time per searched PDA. An allowance of eight extra attempts
(12,000 CU) is **exceeded** about 0.20% (`2^-9`). These are model probabilities, not measured failure rates;
selected/adversarial seeds need not follow this distribution.

The variable execution searches are zero for co-signed and swap deposits, one
for StepDelegate deposits, and three for each fill flow (fill status, fill payer,
recipient ATA). Buffer initialization and each write search one variable PDA.
With an eight-attempt allowance for each of `n` searches, the union bound on
exceeding the total allowance is at most approximately `n / 512` under that model
(about 0.59% for three searches); it is conservative because unused allowances
can offset extra attempts elsewhere. Add allowances to a baseline with zero
extra variable attempts, not to an unadjusted sample maximum. This only models
bump-search variation in the tested paths. Simulate the actual transaction and
apply the configured padding whenever possible; neither the highest observed
CU nor 10% padding on an old fixture is a bound for unseen orders.

## Interpreting distributions and bidding

The reporter uses nearest-rank p50/p90/p95/p99, including zero rates and excluding
cycles missing a base fee or required rate. USD statistics additionally require a
valid same-cycle quote. Cost percentiles are calculated separately for each CU
fixture, then displayed as the minimum/maximum of those fixture percentiles.
They do not multiply a rate percentile by a recent SOL price. Cycles receive equal
weight; overlapping RPC windows are correlated and are not independent slots or
observed transaction landing probabilities.

Jussi's `with_bid_volatility_margin` adjusts priority rates only when bidding,
using its configured per-chain percentage (or global default). These reports
exclude that margin. For a bid comparison, apply the actual configured margin to
the rate before per-transaction priority-fee rounding; do not multiply signature
fees or rent, or apply another CU margin. A zero rate stays zero. The fixed 50k
scenario remains the explicitly requested baseline, independent of bidding policy.
