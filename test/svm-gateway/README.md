# SVM V5 real-Gateway conformance

Run `yarn test-svm-gateway`. It builds Gateway and PrefundedAdapter from the immutable `GATEWAY_COMMIT` in
`reference.ts`, builds this checkout's SpokePool with `--features test`, generates only the target test IDL, and starts
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

While `solana-v5` is private, run this lane locally with existing repository access; do not add a cross-repository
credential to `contracts` CI. Ordinary PR checks run `yarn test-svm-gateway-vectors` for the dependency-free hash
fixture, but do not run the real-Gateway lane. Changes in `test/svm-gateway` also trigger the ordinary SVM tests.

After `solana-v5` is public, add CI coverage using a public checkout at the immutable `GATEWAY_COMMIT`, without a
cross-repository token or approval environment. This is a temporary CI limitation, not a protocol blocker.
Reuse `.github/actions/setup-solana-anchor` to derive this repository's toolchain versions and the `NODE_VERSION`
setting in `pr.yml`. If the Gateway's separate Anchor CLI is downloaded as a release binary, verify it against a
reviewed, pinned SHA-256 checksum (`sha256sum -c`) before execution; a versioned download URL is not an integrity check.

This is a V5 integration test binary, not a verified production release build. The pinned compiler currently reports
an oversized account-validation stack frame in the legacy `FillRelay` handler;
this lane does not exercise or certify that handler. Slow-fill handlers have been removed (see
[SVM upgrade compatibility](../../programs/svm-spoke/README.md)). The existing verified-build and ordinary SVM lanes remain
separate requirements.

`reference.ts` is a test-only wire encoder. It mirrors the Gateway Borsh tape/amount/meta/JIT/buffer transport without
importing the foreign Rust workspace or exporting a production order builder. All command accounts are committed or
explicit injected slots; the outer remaining-account list is only a lookup pool. Status and payer slots are injected
because their addresses depend on the relay/root or submitter; the adapter derives their expected addresses.
Large committed tapes use the Gateway's content-addressed parameter buffer because lookup tables cannot compress
instruction data. Failed executions leave the buffer available for explicit cleanup.

The suite covers StepDelegate and prefunded source deposits, standard deposit identities and witnesses, external and
in-place destination delivery, first-fill-wins siblings, root mismatch and reuse, account/dispatch rejection, payer
funding/reclaim/withdrawal, and downstream rollback. Root reuse examples fund and fully deliver each execution.

Delivery tests deliberately separate two results:

- A single in-place fill followed by a post-fill floor and mandatory full-balance terminal transfer delivers its
  observed balance. The `canonicalInPlace` helper emits only this template. The production builder must also bind the
  transfer destination to an outcome acceptable to each deposit matching the root.
- Raw unsafe paths can succeed: zero/short consumption, or two distinct fills observing one unchanged balance. A
  fixed `min X` floor and full drain protect only `X`. Even a floor summing committed minima fails to cover larger JIT
  output amounts. `assertAggregateDelivery` is an accounting oracle for the actual amounts and actual delivery, not
  an authorization check or proof over all reachable routes. Keep aggregate/action paths disabled until their full
  proportional or aggregate delivery rule is proved by the owning builder.

`ALLOW_REVERT` is unsupported by this Gateway, so an optional downstream command fails atomically. A separate test
submits an actual failing transaction after the fill and transfer, checks `meta.err`, and proves that fill status,
tokens and payer rent were rolled back. It decodes the attempted `FilledRelay` event from that failed receipt's inner
instructions and matches its deposit ID; such events never count as successful settlement.

The additional `v5_gateway_path.json` vector is a deterministic consumption-tape/hash fixture with placeholder keys,
independently checked by Rust and Solidity as well as TypeScript. Existing `v5_adapter_v1.json` vectors continue to
cover deposit/fill input bytes, dispatch, signature and deposit-ID domains.

API builders and relayers must reuse the EVM delivery policy, port applicable tests, and validate supported paths
before enabling SVM Across. Unsupported action/aggregate shapes stay disabled; supporting them is not required
to enable validated routes.

Companion documentation belongs in `solana-v5/AGENTS.md` (SpokePool adapter relationship and shared-vault trust boundary),
`contracts-v5/docs/SPOKE_V5_FILLS.md` (SVM continuing-tape/proportional-delivery counterpart), and each owning off-chain
repository's route-enablement/runbook documentation. Those repositories are not edited by this step.
