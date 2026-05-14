# Registry Routes — Design & Implementation Plan

This document specifies the **Registry Routes** variant of the counterfactual deposit system and lays out the changes required to ship it. It assumes familiarity with the Enumerated Routes implementation currently in `contracts/periphery/counterfactual/` and with the trade-off analysis in [`DESIGN_COMPARISON.md`](./DESIGN_COMPARISON.md).

## 1. Goals

The current (Enumerated Routes) design pins source-chain identifiers — bridge periphery addresses, input-token addresses, CCTP `sourceDomain`, OFT `srcEid`, wrapped-native — into either implementation immutables or merkle-leaf params. The consequences are:

- Different impl bytecode on each chain → different impl addresses → the chain-agnostic CREATE2 address property is only preserved by the dispatcher + factory, not by impls.
- The SDK has to maintain a per-chain token/periphery address registry that must stay perfectly in sync with chain reality.
- Any bridge contract upgrade or canonical-token migration breaks every live counterfactual address.

Registry Routes addresses all three by introducing an on-chain `ChainConfig` registry that stores chain-local address mappings keyed by **stable, chain-agnostic IDs**. Implementations stop reading chain-specific immutables and instead resolve everything they need from the registry at execute time.

The result:

- One impl bytecode per bridge type, deployed deterministically → **same impl address on every EVM chain**.
- Leaves carry IDs instead of raw source-chain addresses → smaller leaves, SDK works in ID-space.
- Bridge upgrades and source-side token migrations become a governance action against the registry rather than a forced regeneration of every live deposit address.

## 2. Architecture

### 2.1 Components

```
┌────────────────────┐         ┌──────────────────────────┐
│  ChainConfig       │         │  Impl: SpokePool / CCTP  │
│  (this chain only) │◀────────│  / OFT — chain-agnostic, │
│                    │  reads  │  same address everywhere │
└────────────────────┘         └──────────────────────────┘
        ▲                                  ▲
        │ admin updates                    │ delegatecall via dispatcher
        │                                  │
   Multisig + Timelock              CounterfactualDeposit clone
                                    (immutable arg: merkleRoot)
```

`ChainConfig` is deployed once per chain, at a deterministic address (no constructor args), and is mutable through a high-bar admin path. Each implementation contract takes `address registry` as its **only** constructor arg and is itself deployed deterministically. Same bytecode + same constructor arg → same impl address on every chain.

The clone and dispatcher (`CounterfactualDeposit`) are unchanged: same merkle-dispatch flow, same EIP-1167 immutable-args clone, same `(implementation, keccak256(params))` leaf format.

### 2.2 What lives where

| Datum                                                                                                                   | Today (Enumerated)         | Registry Routes                                                  |
| ----------------------------------------------------------------------------------------------------------------------- | -------------------------- | ---------------------------------------------------------------- |
| Bridge periphery address (CCTP/OFT)                                                                                     | Impl immutable             | `registry.bridges[BRIDGE_ID]`                                    |
| SpokePool address                                                                                                       | Impl immutable             | `registry.bridges[SPOKE_POOL_ID]`                                |
| Wrapped native token                                                                                                    | Impl immutable             | `registry.tokens[WRAPPED_NATIVE_ID]`                             |
| CCTP `sourceDomain`                                                                                                     | Impl immutable             | `registry.cctpSourceDomain`                                      |
| OFT `srcEid`                                                                                                            | Impl immutable             | `registry.oftSrcEid`                                             |
| SpokePool `signer`                                                                                                      | Impl immutable             | `registry.spokePoolSigner`                                       |
| Source-side `inputToken` (CCTP `burnToken`, OFT `token`, SpokePool `inputToken`)                                        | Raw address in leaf params | `tokenId` in leaf params; resolved by `registry.tokens[tokenId]` |
| Destination-side fields (`outputToken`, `finalToken`, `destinationChainId`, `destinationDomain`, `dstEid`, `recipient`) | Raw values in leaf         | **Unchanged** — still raw values in leaf                         |
| Per-clone `merkleRoot`                                                                                                  | Clone immutable arg        | **Unchanged**                                                    |

The registry is intentionally **source-chain-scoped**: it resolves identifiers for things deployed on the same chain it lives on. Destination-side identifiers stay in the leaf as raw bytes32 / uint256 because the source-chain registry has no authoritative view of destination chains. (A cross-chain mapping — `(tokenId, chainId) → address` — is a possible v2 extension; see §8.)

### 2.3 What changes vs. Enumerated Routes

- **New contract**: `ChainConfig` (registry + admin).
- **Refactor**: `CounterfactualDepositSpokePool`, `CounterfactualDepositCCTP`, `CounterfactualDepositOFT` — constructors drop chain-specific args, take only `registry`. `execute()` reads from registry instead of immutables. Param structs swap raw addresses for IDs.
- **Unchanged**: `CounterfactualDeposit` (dispatcher), `CounterfactualDepositFactory`, `WithdrawImplementation`, `AdminWithdrawManager`. The dispatch path doesn't care what's inside `params`.

## 3. `ChainConfig` contract

### 3.1 Storage

```solidity
contract ChainConfig is Ownable2Step {
  mapping(uint32 bridgeId => address) public bridges;
  mapping(uint32 tokenId => address) public tokens;

  // Chain-specific scalars used by impls.
  uint32 public cctpSourceDomain;
  uint32 public oftSrcEid;
  address public spokePoolSigner;
}
```

Notes:

- **IDs are `uint32`.** Plenty of headroom; cheaper calldata than `bytes32`; trivial to encode in a struct field.
- **Single flat mappings**, not per-bridge sub-mappings. This keeps the impl-side lookup to one SLOAD per id and avoids reserving an outer key.
- **No `chainId` keying.** Each chain has its own `ChainConfig` instance; the chain is implicit. If a chain-aware cross-chain mapping is ever needed (§8), it can be added without breaking the flat layout.
- Scalars are typed individually rather than via a generic `mapping(bytes32 => bytes32)` to keep impls readable and gas predictable.

### 3.2 ID allocation

IDs are **assigned globally and frozen**. The same ID means the same thing on every chain (`USDC_ID = 1` is USDC everywhere it exists). Concretely:

| Domain  | Example IDs                                                         |
| ------- | ------------------------------------------------------------------- |
| Bridges | `SPOKE_POOL = 1`, `CCTP_SRC_PERIPHERY = 2`, `OFT_SRC_PERIPHERY = 3` |
| Tokens  | `USDC = 1`, `USDT = 2`, `DAI = 3`, `WRAPPED_NATIVE = 99`            |

A short constants file (`ChainConfigIds.sol`) exposes these as named constants for use by tests, scripts, and SDKs.

If a token doesn't exist on a chain, `tokens[id]` returns `address(0)` and any impl that looks it up will revert at `transferFrom` or `forceApprove`. Impls also explicitly check for `address(0)` from `bridges[id]` (defensive — see §6.2).

### 3.3 Admin model

`ChainConfig` is owned by a **timelock**, which is owned by a **multisig**. All mutating functions are `onlyOwner`:

```solidity
function setBridge(uint32 id, address addr) external onlyOwner;
function setToken(uint32 id, address addr) external onlyOwner;
function setCctpSourceDomain(uint32 v) external onlyOwner;
function setOftSrcEid(uint32 v) external onlyOwner;
function setSpokePoolSigner(address s) external onlyOwner;
```

Each emits an event:

```solidity
event BridgeSet(uint32 indexed id, address indexed addr);
event TokenSet(uint32 indexed id, address indexed addr);
event CctpSourceDomainSet(uint32 v);
event OftSrcEidSet(uint32 v);
event SpokePoolSignerSet(address indexed s);
```

Timelock delay is a deployment parameter; the recommended value is the same window users need to react and run a withdraw (e.g., 48h). This is the user-visible safety boundary: after a malicious or mistaken registry change is queued, users have until execution to call `signedWithdrawToUser` / `directWithdraw` to recover funds.

### 3.4 Deterministic deployment

`ChainConfig` is constructed with one argument: the initial owner (the timelock). For the **same timelock address** to exist on every chain, the timelock itself must be deterministically deployed (a CreateX or Safe SingletonFactory recipe with the same bytecode + salt on every target chain).

If perfect cross-chain timelock alignment is too operationally heavy, an alternative is to construct `ChainConfig` with **no args** and rely on a two-step ownership transfer: deploy → `transferOwnership(timelock)` immediately after. The contract address stays the same; the owner becomes the per-chain timelock.

I recommend the second option. It removes the cross-chain timelock-address coupling from the deployment story and keeps `ChainConfig`'s bytecode/address truly chain-independent.

### 3.5 Why not UUPS?

`ChainConfig` is mutable in storage but **not** upgradeable in bytecode. The reasons:

- An upgradeable registry recreates the global trust point we're already accepting and stacks a second one on top.
- Storage migrations on a registry that's consulted by every active counterfactual deposit are exceptionally dangerous.
- All operational changes we care about (new bridge versions, new tokens, migrated tokens) are storage mutations, not logic changes. Bytecode upgrade buys us nothing.

If we ever need to extend the schema (e.g., add a new typed scalar), we deploy a sibling registry contract and migrate impls to read it. That's a clean, auditable boundary.

## 4. Implementation refactor

Each bridge-specific implementation changes in three ways:

1. Constructor takes `address registry` only.
2. `execute()` reads previously-immutable values from the registry.
3. The `*DepositParams` struct swaps raw source-side addresses for IDs.

### 4.1 `CounterfactualDepositCCTP`

```solidity
struct CCTPDepositParams {
    uint32 destinationDomain;
    bytes32 mintRecipient;
    uint32 burnTokenId;          // was: bytes32 burnToken
    bytes32 destinationCaller;
    uint256 cctpMaxFeeBps;
    uint32 minFinalityThreshold;
    uint256 maxBpsToSponsor;
    uint256 maxUserSlippageBps;
    bytes32 finalRecipient;
    bytes32 finalToken;
    uint32 destinationDex;
    uint8 accountCreationMode;
    uint8 executionMode;
    bytes actionData;
    uint256 executionFee;
}

constructor(address _registry) { registry = ChainConfig(_registry); }

function execute(bytes calldata params, bytes calldata submitterData) external payable {
    CCTPDepositParams memory dp = abi.decode(params, (CCTPDepositParams));
    CCTPSubmitterData memory sd = abi.decode(submitterData, (CCTPSubmitterData));

    address burnToken    = _requireToken(dp.burnTokenId);
    address srcPeriphery = _requireBridge(CCTP_SRC_PERIPHERY);
    uint32  sourceDomain = registry.cctpSourceDomain();

    // ... rest of execute logic, using burnToken / srcPeriphery / sourceDomain ...
    // (quote.burnToken is set to bytes32(uint256(uint160(burnToken))))
}
```

`_requireToken` / `_requireBridge` revert with `RegistryUnset(id)` on `address(0)`. The quote sent to `srcPeriphery` still carries the resolved raw `burnToken` address as `bytes32`, so periphery-side signature verification is unaffected.

### 4.2 `CounterfactualDepositOFT`

Same pattern. `OFTDepositParams.token` (address) → `tokenId` (uint32). Constructor → `(registry)`. `oftSrcPeriphery` → `registry.bridges[OFT_SRC_PERIPHERY]`. `srcEid` → `registry.oftSrcEid()`.

### 4.3 `CounterfactualDepositSpokePool`

`SpokePoolDepositParams.inputToken` (bytes32) → `inputTokenId` (uint32). `outputToken`, `recipient`, `destinationChainId` stay raw (destination-side). Constructor → `(registry)`. `spokePool` → `registry.bridges[SPOKE_POOL]`. `wrappedNativeToken` → `registry.tokens[WRAPPED_NATIVE]`. `signer` → `registry.spokePoolSigner()`.

Native-asset support: the param leaf encodes `inputTokenId = NATIVE_ASSET_ID` (a reserved ID). `registry.tokens[NATIVE_ASSET_ID]` returns the `NATIVE_ASSET` sentinel (`0xEee…EEeE`). The impl's existing `isNative` check is unchanged.

EIP-712 typehash for `ExecuteDeposit` is **unchanged** — the signer still authorizes the dynamic execution-time fields. The `paramsHash`-binding property comes from the merkle-leaf preimage, not from the signature.

### 4.4 Multi-leaf-same-impl safety

The dispatcher's existing safety property — that a clone's tree shouldn't contain two leaves with the same impl address unless `paramsHash` is part of the signed authorization — is unchanged. With Registry Routes the impl address is **the same on every chain**, so two leaves sharing the same `CounterfactualDepositCCTP` impl across chains is now the _normal_ case. This is fine: leaves still differ by `params`, the merkle proof verifies the exact leaf, and `params` decoding pins the route end-to-end.

What's new: a single clone could now legitimately contain two leaves with the same impl that differ only in `inputTokenId`. The CCTP/OFT impls accept this — their submitter-data signature is validated by the periphery against the resolved token, so cross-token replay isn't possible. The SpokePool impl is the one to scrutinize: its EIP-712 doesn't cover `inputToken`. Today this is fine because trees don't enumerate same-impl multi-token-per-chain leaves; under Registry Routes the SDK still avoids that pattern. If we ever want to relax it, we'd add `inputTokenId` to the EIP-712 typehash. **Recommendation:** add it now, even though the SDK won't (yet) emit colliding leaves — it's a one-line audit-surface reduction and forecloses a footgun.

## 5. Leaf shape, tree size, SDK impact

Leaf preimage and double-hash format are unchanged. The only difference is the inner `params` payload:

| Field           | Enumerated                                   | Registry                              |
| --------------- | -------------------------------------------- | ------------------------------------- |
| Source token    | `bytes32 inputToken` / `burnToken` / `token` | `uint32 inputTokenId` / `burnTokenId` |
| Everything else | Same                                         | Same                                  |

Tree size is **identical** to Enumerated for the same enumeration policy (chains × tokens × bridges). Registry Routes does not shrink trees — that's the Signed Routes win, not this one. Per-leaf calldata shrinks slightly (a `uint32` replaces an `address`), but proof depth is unchanged.

SDK changes:

- Tree builder works in IDs, not addresses.
- Per-chain bridge/token address tables are deleted from the SDK; chain-id → registry-address is the only on-chain lookup needed (and the registry address is the same on every chain).
- Address derivation logic is unchanged — it's still `predictDeterministicAddressWithImmutableArgs(impl, merkleRoot, salt)`. The impl address is now the same on every chain.

## 6. Trust & failure modes

### 6.1 New trust dependency

Registry admin (multisig + timelock) can:

- Redirect every live clone by pointing a bridge ID at a malicious contract.
- Brick every live clone by setting a bridge or token to `address(0)`.
- Effectively change a signer (for SpokePool) by overwriting `spokePoolSigner`.

The timelock window is the only mitigation; users monitor `ChainConfig` events and run `directWithdraw` / `signedWithdrawToUser` if a queued change looks wrong. This monitoring obligation needs to be in the operational runbook and integrator docs.

### 6.2 Defensive checks in impls

Every registry read that produces an address goes through `_requireBridge` / `_requireToken`, which revert on `address(0)` with `RegistryUnset(uint32 id)`. Without this, a missing-id bug would silently produce zero-address `forceApprove`/`transferFrom` calls, which on many tokens revert with opaque errors. Explicit revert preserves the **honest-mistake → loud-revert → safe withdraw** property that the design comparison highlights.

### 6.3 Reentrancy & registry as untrusted call

The registry is read-only from the impl's perspective. Reads are plain SLOADs through public mappings/getters; no external code is invoked. Even so, treat the registry as an integration boundary: never use registry-returned addresses inside `delegatecall`. (The current impls only use them as `call` targets and `IERC20` token operations, which is fine.)

### 6.4 Race conditions

A relayer's `execute()` could be sandwiched by a registry update. The timelock window is the user's safety boundary; for a relayer mid-mempool, the risk is that an execute sent before the update lands after the update with stale assumptions. Mitigation: relayer infrastructure should re-quote / re-simulate after observing any `BridgeSet` / `TokenSet` event for an ID it cares about. Document this.

### 6.5 Honest-mistake recovery

If the registry is set to a wrong address (typo, wrong network), executes revert at the bridge call (wrong token: `transferFrom` reverts; wrong periphery: function selector or signature check reverts). Funds in the clone remain untouched and the existing withdraw paths (`AdminWithdrawManager.signedWithdrawToUser`, `directWithdraw`) recover them. This matches the design-comparison failure-mode column.

## 7. Implementation plan

Sequenced so each step is independently reviewable and testable.

### Step 1 — `ChainConfig` and ID constants

- Add `contracts/periphery/counterfactual/ChainConfig.sol` (storage, setters, events, `Ownable2Step`).
- Add `contracts/periphery/counterfactual/ChainConfigIds.sol` (constants: `SPOKE_POOL`, `CCTP_SRC_PERIPHERY`, `OFT_SRC_PERIPHERY`, `WRAPPED_NATIVE`, `NATIVE_ASSET_ID`, plus initial token IDs).
- Foundry tests in `test/evm/foundry/local/ChainConfig.t.sol`:
  - Only owner can mutate.
  - Events emitted with correct args.
  - Zero-address writes allowed (used for de-registering); reads of unset IDs return zero.
  - Ownership transfer two-step works.

Deliverable: a green `yarn test-evm-foundry -- --match-contract ChainConfig`.

### Step 2 — Refactor impls to read from registry

For each of CCTP, OFT, SpokePool, in separate PRs:

- Replace chain-specific immutables with a single `ChainConfig public immutable registry`.
- Swap `inputToken` (or equivalent) in the param struct to a `uint32 *TokenId`.
- Add `_requireToken` / `_requireBridge` helpers (deduplicated into a small `RegistryReader` mixin or kept inline — propose mixin).
- For SpokePool: include `inputTokenId` in the `ExecuteDeposit` EIP-712 typehash (see §4.4).
- Update local Foundry tests:
  - Replace per-test constructor args with a registry deployment + setters.
  - Add a "registry unset → revert with `RegistryUnset(id)`" case per impl.
  - Add a "registry updated mid-flight → new value wins on next execute" case to lock in the no-caching invariant.

Recommend doing **CCTP first** (smallest blast radius, no native handling), then **OFT** (same shape, plus `srcEid`), then **SpokePool** (native handling, signer, biggest test surface).

### Step 3 — Update factory / dispatcher tests

Dispatcher and factory don't change, but their tests reference impl construction. Sweep `test/evm/foundry/local/CounterfactualDeposit*.t.sol` for `new CounterfactualDeposit{CCTP,OFT,SpokePool}(...)` and migrate to the registry-backed setup.

A shared test helper (`CounterfactualTestBase` or similar) that deploys a fully-populated registry and returns its address will keep the per-bridge test files focused.

### Step 4 — Deployment scripts

Add Foundry deploy scripts under `script/periphery/counterfactual/`:

- `DeployChainConfig.s.sol` — deterministic deploy + `transferOwnership(timelock)`.
- `DeployCounterfactualRegistryImpls.s.sol` — deterministic deploy of the three refactored impls, each constructed with the canonical registry address.
- `ConfigureChainConfig.s.sol` — populates bridges/tokens/scalars for a target chain from a JSON config.

Follow the existing conventions in `script/utils/DeploymentUtils.sol`; record addresses through the standard broadcast/deployed-addresses pipeline so `broadcast/deployed-addresses.json` stays the canonical source.

### Step 5 — SDK migration

(Out of scope for this repo, but required for any end-to-end demo.) Strip per-chain address tables; emit IDs into leaves; bind to the canonical impl addresses; consume `ChainConfig` events for monitoring.

### Step 6 — Docs & runbook

- Update `contracts/periphery/counterfactual/README.md` to describe the registry pattern.
- Add `RUNBOOK_CHAIN_CONFIG.md` covering: how to queue a registry update, what to monitor, the user-side withdraw response procedure, and the audit checklist for new IDs.
- Mark Registry Routes as the chosen path in `DESIGN_COMPARISON.md` (or add a "decision" header pointing to this doc).

### Step 7 — External audit gate

The audit deltas (per §148–154 of `DESIGN_COMPARISON.md`): new ~150–200-LoC contract + chain-agnostic impl refactor across three files. Items to flag for the auditor explicitly:

- `ChainConfig` admin gating + timelock integration.
- Zero-address handling in `_requireBridge` / `_requireToken`.
- That impls never cache registry reads across the same `execute()` call (each lookup is fresh).
- The `inputTokenId`-in-EIP-712 change for SpokePool.
- Multi-leaf-same-impl behavior under Registry Routes is by design (§4.4).

## 8. Future extensions (out of scope for v1)

- **Cross-chain token mapping.** `mapping(uint32 tokenId => mapping(uint256 chainId => address))` to let the registry resolve `outputToken` / `finalToken` from IDs as well. Restores the "destination-side token migration is survivable" property. Adds storage + governance load proportional to the number of supported destination chains.
- **Hybrid with Signed Routes.** Registry resolves bridge contracts; signer authorizes per-call source token from a registry-bounded set. Smaller trees + survives bridge migration + can opt in to longer-lived addresses. Larger contract diff; defer until v1 ships.
- **Per-ID rate limiting.** A simple admin-controlled `mapping(uint32 => uint256) maxFlowPerEpoch` would let governance throttle a freshly-rotated bridge or token without breaking it. Probably unnecessary if the timelock window is generous.

## 9. Open questions to confirm before implementation

1. **Timelock owner model**: confirm we want per-chain timelocks owning per-chain `ChainConfig` instances (recommended), vs. a single timelock at a deterministic cross-chain address.
2. **Initial ID list**: enumerate the bridge/token IDs we plan to ship with so the constants file is correct on day one.
3. **SpokePool typehash change**: confirm adding `inputTokenId` to `ExecuteDeposit` is acceptable (it changes the off-chain signer payload shape).
4. **Native-asset ID**: confirm using a reserved sentinel token ID rather than a special-case branch in each impl.

Resolve these before Step 1.
