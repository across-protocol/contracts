# AI Deployment Config Checker

This folder is intended to hold a PR-time deployment configuration checker for new EVM deployments recorded under `broadcast/**/run-latest.json`.

This document is not just usage documentation. It is the implementation plan another LLM should follow to build or rebuild the checker cleanly in this repo.

## Goal

When a pull request introduces new deployment receipts in `broadcast/`, the checker should:

1. Detect newly deployed contracts from those changed receipts.
2. Determine which zero-argument getters are likely configuration-related.
3. Query those getters onchain using configured RPC URLs.
4. Gather deterministic evidence from the repo and the chain.
5. Ask an LLM to assess whether each value appears correctly configured.
6. Post or update a PR comment containing a per-variable report.
7. Fail CI only for high-confidence incorrect configuration.

The intended report row per checked variable is:

- variable name
- observed value
- verdict: `correct`, `incorrect`, or `uncertain`
- confidence: `0-100`
- reasoning

## Non-Goals

The first version should not attempt to:

- understand arbitrary parameterized getters
- fully analyze mappings or dynamic list-returning getters
- reason about mutable runtime state like counters, roots, balances, timestamps, liabilities, or historical metrics
- use the LLM as the primary discovery mechanism

## Core Design

The checker should be hybrid, not AI-only.

- Deterministic logic decides what to inspect and gathers concrete evidence.
- The LLM interprets ambiguous cases and writes the final reasoning.

This is the most important design constraint. A fully AI-driven discovery pass will be unstable, hard to audit, and prone to silently skipping important config getters.

## Repo Context To Reuse

The checker should explicitly reuse these repo artifacts and conventions:

- `broadcast/**/run-latest.json`
- `broadcast/deployed-addresses.json`
- `generated/constants.json`
- Foundry artifacts in `out/`
- existing chain/RPC naming convention like `NODE_URL_<chainId>`

Relevant existing files:

- [script/utils/ExtractDeployedFoundryAddresses.ts](/Users/taylor/risk-labs/ai-deploy-config-checker/script/utils/ExtractDeployedFoundryAddresses.ts)
- [script/utils/Constants.sol](/Users/taylor/risk-labs/ai-deploy-config-checker/script/utils/Constants.sol)
- [script/utils/DeploymentUtils.sol](/Users/taylor/risk-labs/ai-deploy-config-checker/script/utils/DeploymentUtils.sol)
- [broadcast/deployed-addresses.json](/Users/taylor/risk-labs/ai-deploy-config-checker/broadcast/deployed-addresses.json)
- [generated/constants.json](/Users/taylor/risk-labs/ai-deploy-config-checker/generated/constants.json)

## Required Inputs

The checker needs these runtime inputs:

- `DEPLOY_CONFIG_BASE_SHA`
- `DEPLOY_CONFIG_HEAD_SHA`
- `DEPLOY_CONFIG_PR_NUMBER`
- `GITHUB_REPOSITORY`
- `GITHUB_TOKEN`
- `ANTHROPIC_API_KEY`
- `DEPLOY_CONFIG_RPC_URLS_JSON`

It should also support local fallback env vars:

- `NODE_URL_<chainId>`

`DEPLOY_CONFIG_RPC_URLS_JSON` should take precedence over `NODE_URL_<chainId>`.

## Expected CI Behavior

The GitHub workflow should:

1. Trigger on `pull_request`.
2. Use a path filter to skip when no `broadcast/**/run-latest.json` changed.
3. Install Node dependencies.
4. Install Foundry and forge deps.
5. Build EVM artifacts with `yarn build-evm-foundry`.
6. Run `yarn check-deployment-configs`.
7. Upload the JSON report artifact.
8. Fail only when at least one checked variable is judged `incorrect` with confidence above the chosen threshold.

The workflow should be limited to same-repo PRs at first because secrets are required.

## High-Level Data Flow

The checker should execute in this order:

1. Compute changed `broadcast/**/run-latest.json` files between base and head.
2. For each changed receipt, parse newly added `CREATE` or `CREATE2` transactions.
3. Convert those transactions into deployment targets.
4. Resolve the likely contract artifact for each target.
5. Discover candidate config getters from the artifact ABI and NatSpec.
6. Query those getters onchain.
7. Gather deterministic evidence for each result.
8. Ask the LLM to classify and assess each getter result.
9. Render a sticky PR comment.
10. Emit a machine-readable JSON report.
11. Decide pass/fail.

## Recommended File Structure

Another LLM should keep the implementation split into small modules rather than one large script.

Recommended structure:

```text
script/ai-config-checker/
  README.md
  run.ts
  git.ts
  broadcast.ts
  artifacts.ts
  discovery.ts
  rpc.ts
  evidence.ts
  anthropic.ts
  github.ts
  render.ts
  types.ts
  rules/
    shared.ts
    spokepool.ts
    hubpool.ts
    adapters.ts
    mintburn.ts
```

The current single-file runner can be used as a temporary bootstrap, but the target architecture should look like the structure above.

## Detailed Implementation Plan

### 1. Git Diff Layer

Responsibility:

- compare base vs head
- find changed deployment receipts
- read current and previous receipt contents

Implementation notes:

- use `git diff --name-only <base> <head>`
- only include files matching `broadcast/<script>/<chainId>/run-latest.json`
- for each changed file, read the head version from disk
- read the base version with `git show <base>:<path>` if it exists
- treat missing base file as “entire receipt is new”

Output shape:

```ts
interface ChangedBroadcastFile {
  path: string
  scriptName: string
  chainId: number
  headReceipt: BroadcastReceiptFile
  baseReceipt: BroadcastReceiptFile | null
}
```

### 2. Broadcast Parsing Layer

Responsibility:

- identify newly introduced deployments from a receipt diff

Rules:

- only inspect `transactions[]`
- only include `transactionType` values `CREATE` and `CREATE2`
- require `contractAddress`
- compare head addresses against base addresses from the same receipt
- only keep addresses present in head but not base

Important:

- a receipt may contain multiple new deployments
- a PR may change many receipts
- a deployment may be a proxy deployment whose raw `contractName` is `ERC1967Proxy`

Output shape:

```ts
interface DeploymentTarget {
  address: string
  artifactContractName: string | null
  rawContractName: string | null
  chainId: number
  scriptName: string
  sourcePath: string
  transactionHash: string | null
  transactionType: string | null
  txArguments: unknown[]
}
```

### 3. Artifact Resolution Layer

Responsibility:

- map a deployment target to the most likely Foundry artifact

Primary rules:

- if `contractName !== "ERC1967Proxy"`, prefer that artifact name
- if the deployment is a proxy, infer the intended artifact from the script name
- use `out/**/<Contract>.json`
- prefer exact paths like `out/<Contract>.sol/<Contract>.json`

Fallback logic:

- `DeployArbitrumSpokePool.s.sol` and similar should resolve to `SpokePool`
- `DeployHubPool.s.sol` should resolve to `HubPool`
- `Deploy...Adapter.s.sol` should resolve to the named adapter artifact
- if multiple candidate artifact paths exist, prefer the exact `<Contract>.sol/<Contract>.json` path

If no artifact is found:

- report the deployment as unresolved
- do not fail the entire run immediately
- include a warning in the JSON output and PR comment

### 4. Proxy Inspection Layer

Responsibility:

- inspect ERC1967 implementation and admin slots when possible

Read these slots directly with RPC:

- implementation slot: `0x360894...2bbc`
- admin slot: `0xb53127...6103`

Use this for:

- enriching the report
- giving the LLM more context
- deterministic validation if a getter exposes admin or implementation-like values

Do not assume every deployment is a proxy.

### 5. Deterministic Getter Discovery Layer

Responsibility:

- build a superset of plausible config getters before any LLM involvement

Initial inclusion rules:

- ABI item type is `function`
- `stateMutability` is `view` or `pure`
- zero inputs
- at least one output
- output types are simple enough to normalize safely in v1:
  - `address`
  - `bool`
  - `string`
  - `bytes32`
  - integer types

Initial exclusion rules:

- names that are clearly runtime or noisy:
  - `VERSION`
  - `getCurrentTime`
  - `numberOf*`
  - `*Root*`
  - `*Timestamp`
  - `*Deadline`
  - `*Count`
  - `*Counter`
  - `*Nonce`
  - `chainBalance*`

Initial must-check names:

- `owner`
- `admin`
- `finder`
- `hubPool`
- `spokePool`
- `crossDomainAdmin`
- `wrappedNativeToken`
- `weth`
- `tokenMessenger`
- `messageTransmitter`
- `lineaMessageService`
- `lineaTokenBridge`
- `l1ArbitrumInbox`
- `l1ERC20GatewayRouter`
- `l1CrossDomainMessenger`
- `l1StandardBridge`
- `l1OpUSDCBridgeAdapter`
- `polygonRootChainManager`
- `polygonFxRoot`
- `polygonERC20Predicate`
- `polygonRegistry`
- `polygonDepositManager`
- `scrollERC20GatewayRouter`
- `scrollMessengerRelay`
- `scrollGasPriceOracle`
- `adapterStore`
- `donationBox`
- `hubPoolStore`
- `destinationDomain`
- `sourceDomain`
- `cctpDomain`
- `oftEid`
- `router`
- `bridge`
- `mailbox`
- `signer`
- `quoteSigner`
- `verifier`
- `sp1Helios`

Heuristic candidate names:

- any getter whose lowercased name contains:
  - `owner`
  - `admin`
  - `pool`
  - `token`
  - `wrapped`
  - `messenger`
  - `bridge`
  - `router`
  - `finder`
  - `domain`
  - `store`
  - `adapter`
  - `signer`
  - `verifier`
  - `factory`
  - `mailbox`
  - `endpoint`

Output shape:

```ts
interface CandidateGetter {
  name: string
  signature: string
  stateMutability: string
  deterministicPriority: "must_check" | "candidate"
  whySelected: string
  natspecNotice: string | null
  natspecDetails: string | null
}
```

### 6. AI-Assisted Getter Classification Layer

Responsibility:

- refine the deterministic candidate set, not replace it

Policy:

- deterministic discovery decides the superset
- the LLM decides whether a candidate should appear in the final report
- the LLM must not be allowed to silently erase deterministic must-check coverage without explanation

Prompt inputs per candidate:

- contract name
- chain ID
- deployment address
- getter name and signature
- NatSpec notice/details
- deterministic selection reason
- observed value
- deterministic evidence

Required LLM output per getter:

```json
{
  "variable_name": "hubPool",
  "should_include": true,
  "verdict": "correct",
  "confidence": 98,
  "reasoning": "This getter returns the canonical hub pool address for the hub chain.",
  "evidence_refs": ["name_derived_expectation", "broadcast/deployed-addresses.json"]
}
```

If the LLM omits a getter:

- default it to `uncertain`
- keep `should_include: true`
- explain that the LLM omitted it

### 7. RPC Read Layer

Responsibility:

- perform all onchain calls deterministically

Requirements:

- use `ethers.providers.JsonRpcProvider`
- select RPC by chain ID
- normalize addresses to checksum form
- convert BigNumbers to decimal strings
- keep the raw response string for debugging

Value normalization rules:

- `address`: checksum
- `uint*` / `int*`: decimal string
- `bool`: boolean
- `string`: string
- `bytes32`: hex string
- arrays of supported scalar types: normalized element-wise
- unsupported complex nested structures: either flatten conservatively or skip in v1

The RPC layer should never ask the LLM to make a call.

### 8. Deterministic Evidence Layer

Responsibility:

- attach concrete reference facts for each getter result

Evidence sources:

1. `generated/constants.json`
2. `broadcast/deployed-addresses.json`
3. ERC1967 proxy slot reads
4. getter-name-derived expectations
5. chain-family-derived expectations
6. constructor/initializer args, if reliably available

Evidence examples:

- observed `hubPool()` equals canonical `HubPool` address in `broadcast/deployed-addresses.json`
- observed `wrappedNativeToken()` equals `generated/constants.json.WRAPPED_NATIVE_TOKENS.<chainId>`
- observed `cctpDomain()` equals `generated/constants.json.PUBLIC_NETWORKS.<chainId>.cctpDomain`
- observed `admin()` equals proxy admin slot value
- observed `finder()` equals mainnet finder in `L1_ADDRESS_MAP`

Each evidence item should be explicit and machine-readable:

```ts
interface EvidenceItem {
  kind: string
  source: string
  status: "match" | "mismatch" | "related" | "observed" | "unavailable"
  details: string
  expected?: Primitive
  actual?: Primitive
}
```

### 9. Rule Modules

Responsibility:

- capture contract-family-specific expectations that are too specific for generic name heuristics

Recommended families:

- `spokepool.ts`
- `hubpool.ts`
- `adapters.ts`
- `mintburn.ts`

Each rule module should expose:

- a matcher for contract family or artifact name
- additional must-check getters
- optional skip rules
- optional expected-value derivation functions
- optional explanatory text for mismatches

Example:

- SpokePool-like contracts should always check `hubPool`, `crossDomainAdmin`, `wrappedNativeToken`
- adapter-like contracts should bias toward bridge/messenger/router/domain getters
- periphery-like contracts should check signer, verifier, spokePool, token messenger, domain/eid values

### 10. Anthropic Integration Layer

Responsibility:

- call the Claude API directly with a structured payload

Use:

- direct HTTPS call to `https://api.anthropic.com/v1/messages`
- strict JSON-only response requirement

Prompt requirements:

- do not ask for prose around the JSON
- explicitly enumerate the allowed verdict values
- instruct the model to use deterministic evidence first
- instruct the model not to infer certainty where evidence is weak

Failure behavior:

- if the API call fails, fail the job
- if the JSON is malformed, fail the job
- if one deployment’s model response is malformed, include the raw response in debug logs if safe, but do not leak secrets

### 11. PR Comment Layer

Responsibility:

- create or update one sticky PR comment

Behavior:

- identify the sticky comment by an HTML marker like `<!-- deployment-config-checker -->`
- if found, update in place
- otherwise create a new issue comment on the PR

Recommended comment structure:

1. short header
2. summary table by contract
3. detailed section per contract
4. per-variable table

Recommended summary columns:

- contract
- chain
- address
- checked
- incorrect
- uncertain

Recommended per-variable columns:

- variable
- value
- verdict
- confidence
- reasoning

### 12. JSON Report Layer

Responsibility:

- emit a machine-readable artifact for debugging and future integrations

Write:

- `deployment-config-check-report.json` at repo root during the workflow run

Recommended structure:

```ts
interface FinalReport {
  generated_at: string
  base_sha: string
  head_sha: string
  repository: string
  pr_number: number
  deployments_checked: number
  reports: ContractReport[]
}
```

The workflow should upload this as a GitHub Actions artifact.

### 13. Pass/Fail Policy

Responsibility:

- decide when CI should fail

Initial policy:

- fail only when a checked variable is assessed as `incorrect`
- require confidence to be above a threshold, recommended `>= 80`
- `uncertain` should not fail CI in v1
- missing artifacts or model failures should fail the run because the checker did not complete

This is conservative enough to avoid flaky CI while still blocking obvious bad deployments.

## Concrete Build Sequence

Another LLM should implement the checker in this order:

1. Create shared `types.ts`.
2. Build `git.ts` and `broadcast.ts`.
3. Build `artifacts.ts`.
4. Build `rpc.ts`.
5. Build `discovery.ts`.
6. Build `evidence.ts`.
7. Build `anthropic.ts`.
8. Build `render.ts`.
9. Build `github.ts`.
10. Build `run.ts` as thin orchestration glue.
11. Add `package.json` script entry.
12. Add GitHub Actions workflow.
13. Add README usage and secret documentation.

Do not start with the LLM prompt. Start with deterministic discovery and evidence plumbing first.

## Suggested Testing Strategy

The repo currently emphasizes Foundry and script-based workflows. For this checker, tests can start lightweight.

Recommended test layers:

1. Pure unit tests for:
   - receipt diffing
   - artifact resolution
   - getter filtering
   - value normalization
   - evidence derivation
2. Golden tests for:
   - rendered PR comment output
   - final JSON report shape
3. Small integration tests with:
   - mocked Anthropic response
   - mocked GitHub comments API
   - mocked ethers provider

At minimum, another LLM implementing this should make the logic deterministic enough that fixtures can drive it end to end without live RPCs or live Anthropic calls.

## Known Constraints

- Fork PRs should not run this initially because secrets are required.
- GitHub Actions cannot conveniently expose arbitrary dynamic secret names, which is why `DEPLOY_CONFIG_RPC_URLS_JSON` is preferred over many separate RPC secrets.
- Some deployments may use proxies whose artifact name is not directly obvious from the receipt.
- Some config is only inferable via contract-family rules, not generic getter naming.

## Recommended Extensions After V1

- split the current single-file runner into modules
- add contract-family rule files
- add fixture-based tests
- add support for selected parameterized getters where configuration is meaningful
- enrich deterministic evidence with constructor and initializer argument tracing
- add support for comparing against verified deployment manifests beyond `broadcast/deployed-addresses.json`
- include a “skipped getters” section for AI-classified non-config candidates

## Local Usage

Build EVM artifacts first:

```bash
yarn build-evm-foundry
```

Run the checker with explicit PR SHAs and PR number:

```bash
DEPLOY_CONFIG_BASE_SHA=<base_sha> \
DEPLOY_CONFIG_HEAD_SHA=<head_sha> \
DEPLOY_CONFIG_PR_NUMBER=<pr_number> \
GITHUB_REPOSITORY=across-protocol/across-smart-contracts-v2 \
GITHUB_TOKEN=<github_token> \
ANTHROPIC_API_KEY=<anthropic_key> \
DEPLOY_CONFIG_RPC_URLS_JSON='{"1":"https://...","42161":"https://..."}' \
yarn check-deployment-configs
```

Local fallback RPC env vars:

```bash
NODE_URL_1=https://...
NODE_URL_42161=https://...
```

## CI Secrets

The workflow expects:

- `ANTHROPIC_API_KEY`
- `DEPLOY_CONFIG_RPC_URLS_JSON`

Example:

```json
{
  "1": "https://mainnet.example",
  "10": "https://optimism.example",
  "42161": "https://arbitrum.example"
}
```

## Current Scope

The first version should focus on zero-argument `view` and `pure` getters that look config-related by deterministic rules. That scope is intentionally narrow. It is better to be explicit and auditable than broad and vague.
