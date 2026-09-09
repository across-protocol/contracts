# SVM V5 real-Gateway conformance

Run `yarn test-svm-gateway`. It builds Gateway and PrefundedAdapter from the immutable `GATEWAY_COMMIT` in
`reference.ts`, builds this checkout's SpokePool with `--features test`, generates test IDLs, and starts
an isolated validator with all three real programs loaded as upgradeable programs. It does not clone mainnet state.
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
[SVM upgrade compatibility](../../programs/svm-spoke/README.md)). The existing verified-build and ordinary SVM lanes remain
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
