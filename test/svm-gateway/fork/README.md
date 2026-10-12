# V5 Spoke CU estimates using mainnet account snapshots

Run `yarn estimate-svm-fork-cu` from the contracts root. This is a local Agave
account-snapshot replay, not a full historical bank fork or a transaction landing
experiment. Mainnet access only reads accounts and deployed IDL data. All
transactions use deterministic test-only keys and a loopback validator.

The [initial CU and SOL/USD cost snapshot](results/2026-10-12.md) records the
current measured ranges, archive cutoff and binary provenance. Refresh that
snapshot after extending the fee-collection window using the cost-report command
below; a new validator run is needed only when changing the CU workload or its
program/runtime inputs.

## Programs and artifacts

The default lane **does not build Spoke**. It reads the production Spoke SHA-256
from a successful CI job's `Production Spoke SHA-256` log line, checks the existing
`target/deploy/svm_spoke.so` against it, and downloads that run's production IDL.
It also rejects differences in program sources, Cargo dependencies, Anchor config,
verified-build recipe, or build helpers relative to the CI source commit.

Contracts CI uploads IDLs/generated clients, not production `.so` files. Supply an
existing matching verified binary with `SVM_FORK_SPOKE_BINARY` if it is elsewhere.
If no matching binary is available, build it using the repository's verified
production build workflow first; this estimator will not silently substitute a
test-feature or different-compiler binary. The initial validated source is epic
commit `7df8c6fd445b4ec7fd74f6d1d983e5378139c3d4`, CI run `37975260687`.
The measured Spoke is prospective V5 code; the paused deployed Spoke is not used.

Gateway, SPL Token, Associated Token, Raydium CPMM executables, Gateway config,
Spoke state, mints, shared vaults, and pool state come from mainnet. Mutable pool
accounts and program bytes are captured in one finalized `getMultipleAccounts`
response. The Gateway IDL comes from its on-chain IDL account. Mainnet feature
accounts are captured separately; those and the IDL do not have the same atomic
bank context. Executable hashes are checked again on the local validator.

## Run

Use Node 22, installed locked Yarn dependencies, Agave 4.1.2, and authenticated
GitHub CLI. The first run needs GitHub and a mainnet RPC. `SVM_FEE_RPC_URL` is the
same secret environment variable used by the fee collector; it is never written
to the output. `SVM_FORK_CI_RUN` defaults to a successful Checks run at HEAD;
select an earlier compatible run after committing tooling-only changes.

```sh
SVM_FORK_CI_RUN=37975260687 SVM_FORK_FEE_MANIFEST=../jussi/examples/svm-fees/spoke-components.json yarn estimate-svm-fork-cu
```

`SVM_FORK_OUTPUT` must be a new directory (default `target/fork-cu-<timestamp>`).
`SVM_FORK_SAMPLES` defaults to 3, accepts 1–10, and starts a fresh validator and
restores the same pool snapshot for each deterministic payer/recipient sample.
Flow order within a sample is fixed; swaps change the pool for the next flow.
These samples expose address/PDA variation, not a statistical worst-case bound.
Set `SVM_FORK_FLOWS` to a comma-separated selection of `deposit-cosigned`,
`deposit-step-delegate`, `fill-external`, `fill-inplace`, `swap-deposit`,
`fill-swap`, and `fill-jit-swap` to run only those flows in the specified order.

A completed or partially completed run can supply artifacts and its saved snapshot
for offline replay, without fetching CI or mainnet and without rebuilding:

```sh
SVM_FORK_ARTIFACTS=/absolute/previous/run SVM_FORK_SNAPSHOT=/absolute/previous/run/mainnet-snapshot.json SVM_FORK_OUTPUT=/absolute/new/run yarn estimate-svm-fork-cu
```

The offline path rechecks binary/IDL hashes and source compatibility. Keep the
artifact manifest from the verified online run with those files; it is the trusted
provenance input. No production signing keys or Docker service are needed.

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
`provenance.json`, `spoke-artifact.json`, raw snapshot, genesis patches, CI log,
IDLs/binaries, and validator logs/ledgers. Ledgers are retained for debugging.

Focused boundary checks:

```sh
NODE_OPTIONS=--no-experimental-strip-types yarn ts-mocha -p tsconfig.json test/svm-gateway/fork/Estimator.ts
```

## Recalculate SOL/USD costs from a growing Jussi archive

`yarn report-svm-fork-costs` prices the saved CU results offline. No validator,
Docker restart, mainnet RPC, or new CU measurement is needed. Use Node 22:

```sh
yarn report-svm-fork-costs target/fork-cu-20261012-final ../jussi/measurements/chainstack-20261012T132536Z-coverage/snapshots.jsonl target/fork-costs-new
```

Choose a new output directory each time. Repeating the command with the growing
archive includes the additional snapshots. It writes `costs.md`, `costs.json`,
and `fee-evidence.json`. The full JSON includes per-transaction baseline fees, CU sample IDs and timestamps
for extrema, component sets, missing-data counts, prices, and input hashes.

Commit `fee-evidence.json` alongside each checked-in result snapshot (named
`<date>-fee-evidence.json`). This portable review artifact contains the exact
account sets, all derived per-cycle fee rates and corresponding prices/base fees,
the CU/signature/rent inputs, and full raw RPC windows for the rate/cost/price
extrema. `columns` describes each compact observation row; `series` and `flows`
map execution rates to account components. Rates are micro-lamports/CU. `null`
means missing, not zero. Paths, RPC endpoints and credentials are excluded.

These inputs let reviewers recalculate the cost tables without the local archive
and inspect how the extreme rates were derived. Selected raw witnesses do not
independently prove that no larger value existed elsewhere in the full archive;
its exact prefix hash remains the reference for a full audit.

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
