# SVM TypeScript migration plan

Status: step 1 implemented on `sol-cctpv2-scripts`; validation and release handoff are described below. Steps 2 and 3 remain planned. This document separates the CCTP V2 / Solana light-chain migration from the later removal of production Solana TypeScript exports from `contracts`.

## Decisions

- Keep Solana scripts and program tests in `contracts` on Anchor / web3.js v1. CCTP V2 does not require moving to Solana Kit.
- Solana becomes a light chain: no protocol liquidity rebalances between HubPool and the Solana spoke, and origin-only repayment for intents involving Solana. Tokenless root-bundle and admin messages still need delivery.
- Production integration helpers belong downstream, principally in `sdk`.
- Use the CCTP V2 clients already exported by `contracts` for the consumer migration. Move client generation downstream in a later step.
- The eventual IDL-only boundary applies to Solana integrations. Removing EVM artifacts, deployment utilities or shared Merkle utilities is outside this proposal.

The three steps have separate completion criteria. Step 2 depends on the new program interfaces, but does not depend on step 3. Export removal must wait until consumers have replacements.

## Current state

`contracts` already generates and exports `MessageTransmitterV2Client` and `TokenMessengerMinterV2Client`, alongside the spoke, multicall and sponsored-CCTP clients. CCTP V1 clients, IDLs/types, connectors, message helpers and V1 address constants have been removed from the Solana package surface, including deep-import paths. See [client generation](scripts/svm/buildHelpers/generateSvmClients.ts) and [client exports](src/svm/clients/index.ts).

The V2 clients provide generated instructions, account readers and codecs. They do not replace the integration logic that selects receiver accounts, fetches attestations, checks processing status and constructs complete transactions.

The investigation found these dependencies in local consumer source code; it did not establish which paths currently receive production traffic:

| Consumer                    | Relevant dependencies                                                                                                                      |
| --------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------ |
| `sdk`                       | V1 CCTP clients and header decoder for receive/nonce handling; spoke client for account reads, instruction construction and serialization. |
| `relayer`, `relayer-madrid` | V1 bridge/finalizer paths, V2 CCTP clients, spoke refund and liability handling.                                                           |
| `quote-api`                 | V2 burn builders, sponsored-CCTP client, spoke state reader and `MulticallHandlerCoder`.                                                   |
| `indexer`                   | V2 `fetchMessageSent`, IDLs, and spoke event handling through the SDK.                                                                     |

No downstream imports or invocations of `scripts/svm` entry points were found. The coupling is through exported `src/svm` code. In particular, quote-api is affected by eventual export removal even where its CCTP logic already uses V2.

## Step 1: migrate contracts scripts

**Scope:** `contracts`, on `sol-cctpv2-scripts`, based on the CCTP V2 program work in [PR #1548](https://github.com/across-protocol/contracts/pull/1548).

Adapt supported scripts to the new program and light-chain behavior using Anchor / web3.js v1:

- Inventory CCTP V1 usage in scripts and their helpers. Update program connections, message parsing, attestation retrieval, nonce handling and receive-message accounts where needed.
- Review `proposeRebalanceToSpokePool.ts` and `executeRebalanceToSpokePool.ts` by purpose. Remove obsolete token-rebalance workflows. Preserve useful tokenless root/admin delivery and manual recovery functionality under names that describe their new purpose.
- Update remote admin/pause scripts and provide a way to finalize an existing tokenless CCTP V2 message from its source transaction. Exercise both admin and root-bundle delivery.
- Keep useful public-network and cross-chain proof-of-concept scripts in this repo, with internal helpers.
- Distinguish discontinued HubPool/spoke liquidity rebalances from independent CCTP token transfers, including sponsored transfers and relayer inventory operations. Do not remove the latter solely because Solana becomes a light chain.

Remove obsolete CCTP V1 exports now so consumer builds against the migration beta expose dependencies that need updating. This includes V1 client generation, IDLs/Anchor types, connectors, message codecs/attestation helpers and V1 address constants in the SVM utilities. Prune stale generated artifacts so deep imports also fail. Do not introduce new exported production TS helpers. Leave ownership of retained client generation, remaining export cleanup and the broader Kit-test migration for step 3. Generated spoke interfaces also reflect the underlying program upgrade; those compatibility changes are handled in step 2.

**Completion criteria:** obsolete CCTP V1 package exports are absent, including deep imports; supported scripts use CCTP V2; obsolete rebalance entry points are removed or repurposed; relevant program/script checks pass; tokenless delivery and retry/already-processed behavior are covered. Document invocation, prerequisites and recovery usage, including any public-network validation still outstanding.

**Implementation:** replaced the token-rebalance proposal/execution pair with `finalizeCctpV2Message` for all supported tokenless root/admin selectors; remote pause scripts share its internal V2 finalizer and support recovery without EVM credentials. Fill examples now request origin-chain repayment with an explicit repayment address. Retained V2 and non-CCTP client exports/generation and sponsored V2 token flows remain; obsolete CCTP V1 export paths are removed. See the [script guide](scripts/svm/README.md) for commands, tests and outstanding public-network validation. [ACP-226](https://linear.app/uma/issue/ACP-226) tracks this scope.

The standalone finalizer also supports independent incoming token transfers through TokenMessengerMinterV2, using shared receive/nonce/retry logic and separate receiver account builders. Token delivery requires the spoke vault or an explicitly selected destination token account and supports both finalized and unfinalized attestations. Pause scripts remain Spoke-only. Script-local response parsing validates consumed fields and reads finality from message bytes, without changing the exported V2 attestation schema or other retained production helpers. Follow-up validation passed all three focused suites together (29 tests), including token fees, recipient checks, retry/replay and finality boundaries.

**Local validation (2026-09-11):** SVM test-feature build, IDL/client generation, EVM build, TypeScript package build, explicit changed-script/test type-checks and formatting passed. The broad SVM run had 143 passing tests and two new receiver-fixture failures caused by reading just-created state at confirmed commitment. After making the fixture wait for confirmation, the complete receiver suite passed (11 tests); the final attestation/selection suite also passed (10 tests). The entire broad suite was not repeated after the fixture-only fix. Validation used Anchor 0.31.1 and Solana 2.1.21. Public-network end-to-end checks and beta publication remain outstanding.

**Handoff:** prepare a reviewed contracts beta (proposed `6.0.0-beta.0`) after validation, containing the regenerated Spoke IDL/client and matching test-binary artifacts. Generate the published IDLs with `IS_TEST` unset; publish test-feature binaries separately as release artifacts. The interface changes come from PR #1548, not from the script edits alone. A local packed build can unblock initial consumer work; a pinned beta provides the shared step-2 dependency. Publishing the beta and the coordinated on-chain cutover are separate follow-ups.

**V1 export-removal validation:** external IDL/type generation, asset/client generation, a clean TS package build, changed-script/test type-checks, and 11 attestation/selection tests passed. Package-manifest inspection and consumer-style TypeScript/runtime checks confirmed V1 root exports and deep-import paths are absent while V2 and other clients remain available. The validator suite was not repeated for this removal of unused code. The breaking beta has not been published.

## Step 2: migrate consumer behavior using existing clients

**Scope:** SDK first, followed by affected consumers. No new Codama generation pipeline is required in this step.

Build consumers against the pinned migration beta first: removed V1 imports provide a migration checklist. Compilation does not detect every semantic change, so also review light-chain repayment rules and tokenless receiver behavior. Existing production deployments stay pinned until their migration is ready. Any required historical V1 decoding or pre-cutover recovery must have an explicit downstream implementation.

Use `MessageTransmitterV2Client` and `TokenMessengerMinterV2Client` from `contracts`. Add or adapt production integration helpers in the SDK:

- V2 header/body decoding, attestation handling, nonce-PDA derivation and processing-status checks.
- V2 receive-message builders, including the spoke's tokenless root/admin receiver accounts.
- Token transfer account builders where still required by independent CCTP integrations.
- Relevant integration tests and V2 validator fixtures.

The tokenless path may continue using `SvmSpokeClient` from `contracts` for state reads and spoke-specific types. RPC, signing and transaction infrastructure already exists downstream and should be reused. Existing V2 finalizer code in the relayer repos is a useful consolidation source, but its token-mint path must not be assumed to cover tokenless spoke messages.

Consumer changes include:

| Repo                        | Work                                                                                                                                                                                                                      |
| --------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `sdk`                       | Replace V1 finalization/nonce logic, adapt tokenless account construction, and update removed spoke interfaces/events and tests.                                                                                          |
| `relayer`, `relayer-madrid` | Adopt SDK V2 integration helpers; remove spoke-to-HubPool finalization and transfer-liability reads; adapt remaining V1 token integrations; ensure dataworker repayment/refund behavior respects the light-chain model.   |
| `indexer`                   | Update affected spoke event ingestion, including removed `TokensBridged` behavior. Account for historical indexing needs when changing old event support. Existing V2 account readers can remain imported from contracts. |
| `quote-api`                 | Verify compatibility with the upgraded package and light-chain rules. Existing V2 burn, sponsored-CCTP and other unaffected contracts imports can remain.                                                                 |

**Completion criteria:** affected consumers work with the upgraded program and light-chain rules; active migrated paths use V2; tests cover tokenless delivery, nonce/idempotency behavior and retained token-transfer paths. Any retained historical V1 handling is explicit. No new production TS exports or duplicate client generation are added to `contracts`.

Prepare and validate consumer changes against pinned prereleases during review. Coordinate deployment of behavior incompatible with the old program with the on-chain cutover; publishing a package is not itself the cutover. Program/adapter deployment, HubPool configuration and light-chain configuration remain separate operational work.

## Step 3: plan and remove remaining Solana runtime exports

Write the detailed removal plan after steps 1 and 2, using an updated consumer import inventory. This step changes ownership after protocol behavior is working.

Expected scope:

- Add Codama generation in the SDK from versioned IDLs published by `contracts`, including the CCTP V2 and other required program clients. Consumers use SDK exports or generate their own clients from IDLs where appropriate.
- Move required handwritten runtime functionality downstream: chain-ID lookup, multicall instruction compilation and any remaining imported helpers. Reuse existing SDK encoders and utilities.
- Migrate consumer imports and downstream test-only dependencies before deleting contracts exports.
- Review Kit tests in `contracts`; preserve unique program coverage in Anchor tests and client/integration coverage downstream before removing redundant tests.
- Remove contracts' Codama generation, generated-client exports and runtime Solana helper exports. Retain internal Anchor helpers for scripts/tests and the IDL publication pipeline. Verify package contents as well as root exports so deep imports cannot continue consuming internal runtime code.
- Retain program test binaries needed by downstream integration tests as separate build/release artifacts; IDL-only describes the TS integration boundary.

**Completion criteria:** downstream production code no longer imports Solana runtime TS from `contracts`; required integration tests pass; contracts scripts/tests use Anchor / web3.js v1; published Solana interfaces consist of IDLs. Document replacement import paths and the breaking release boundary.

## Why these steps stay separate

Step 1 fixes the repo's operational scripts and removes obsolete CCTP V1 exports to expose consumer dependencies. Step 2 fixes external protocol behavior with clients that already exist. Step 3 moves ownership of those clients and remaining helpers.

Moving client generation into step 2 would introduce temporary duplicate generation without being required for CCTP V2 support. Keeping generation in place until step 3 avoids that work and allows protocol compatibility to be reviewed independently from package/export restructuring.

## References

- [Deferred CCTP migration work](https://risklabs.slack.com/archives/C0BU73GVCJE/p1789076538183739).
- [Anchor/web3.js v1 and eventual IDL-only agreement](https://risklabs.slack.com/archives/D08EJMLPQLX/p1789104534383679).
- Local Circle reference checkout: `/Users/dev/dev/reference/solana-cctp-contracts`.
