# Upgradeable Counterfactuals — Design

Status: design doc, not implementation. Author: Taylor (with Claude). Updated: 2026-06-04.

> **Implementation target: this repo (`across-protocol/contracts`), branch
> `taylor/counterfactual-upgradeable`.** This design supersedes earlier route-policy sketches: there
> is **no `RoutePolicy` contract**. Each counterfactual is a **`BeaconProxy`** that holds its route root
> in storage; the single global **`CounterfactualBeacon`** per chain is its **beacon** (the one shared
> implementation every proxy runs) and governs per-proxy root upgrades.

## Motivation

The base counterfactual system (`contracts/periphery/counterfactual/`) gives users persistent,
reusable deposit addresses via deterministic CREATE2: each address commits a merkle root, and callers
prove a leaf to delegatecall a per-bridge implementation that bridges the address's balance. Today
that root is **immutable** — baked into the clone forever — so a route set can never change without
changing the user-facing address.

This design keeps the deposit mechanism but makes each counterfactual **upgradeable**, adding:

1. **Same address across chains** for a destination identity `(finalRecipient, outputToken,
destinationChainId)`, so a user hands out one address and receives on it from any source chain.
2. **Upgradeable routes** — change the set of routes an address may use without changing the address.
3. **Upgradeable implementation** — fix or extend the dispatch/bridge logic without changing the
   address.
4. **No per-counterfactual admin key** — authorization comes from the counterfactual's own merkle
   tree (deposits, withdraws) and the global `CounterfactualBeacon` (a per-proxy root tree + a global
   current implementation).
5. **Trustless injection** of the per-user fields (recipient, output token, destination chain) into
   bridge calldata.
6. **Dynamic, signed execution fees** — all three bridge implementations accept an `executionFee`
   chosen at execution time via `submitterData`, authorized by an off-chain `signer` and verified
   on-chain (matching the `taylor/counterfactual-route-policy` branch — see _Execution Fees_).

---

## Core Idea

Each counterfactual is a **`BeaconProxy`** (ERC-1967 beacon) rather than an EIP-1167 minimal clone. Its
beacon is the global **`CounterfactualBeacon`**, so every proxy resolves and runs the registry's single
**`implementation()`** live on each call — they are **always on the current implementation**, with no
per-proxy upgrade step and no bootstrap. The proxy stores `activeRoot` (the merkle root authorizing its
deposit routes), initialized from an `initialRoot` passed in the constructor `data` (which also binds
`initialRoot` into the address — see _Address Determinism_).

Two things are mutable post-deploy, and **neither enters address derivation**:

- **`activeRoot`** — the live route set (changed by a per-proxy `updateRoot`).
- **the implementation** — the dispatch/bridge logic, changed **globally** by the admin setting the
  beacon's `implementation`; every proxy picks it up **instantly**, with no per-proxy action.

There is **no owner or admin** on the proxy. Authorization comes from the global `CounterfactualBeacon`,
split along "shared vs. per-proxy":

- **Deposits** (and withdraws) dispatch by merkle proof against the counterfactual's own
  **`activeRoot`** — exactly as in the base system.
- **Implementation** (shared logic) is the beacon's `implementation()` — the admin sets it once and
  **every proxy uses it immediately** (resolved live per call). No per-proxy sync.
- **Root updates** (per-proxy routes) are applied by an executor with a proof against the registry's
  **upgrade tree** of `(proxy, latestRoot)` leaves. They are best-effort — a proxy keeps its `activeRoot`
  until updated; there is no execute-time version gate.

```
═══════════════════════════ DEPOSIT (per counterfactual) ═══════════════════════════

relayer
  │ proxy.execute(implementation, params, submitterData, proof)
  ▼
┌─────────────────────────────┐  proof vs activeRoot (storage)
│ Counterfactual BeaconProxy  │  impl ← beacon.implementation()
│  activeRoot  : storage      │  verify leaf, DELEGATECALL impl
│  (impl resolved via beacon) │
└──────────────┬──────────────┘
               │ delegatecall: address(this) == proxy (holds funds)
               ▼
┌─────────────────────────────────┐  recipient ← finalRecipient (from identity)
│ CounterfactualDeposit{CCTP/OFT/  │  approve(bridge) ; bridge deposit with
│  SpokePool}  (per-bridge impl)   │  native recipient = finalRecipient
└──────────────┬──────────────────┘
               ▼
   SpokePool.deposit / CCTP depositForBurn / OFT send  →  delivered natively on dest


═══════════════════ UPGRADE (global registry = beacon, per chain) ═══════════════════

registry admin                               executor (permissionless)
 │ setImplementation(impl)  ← all proxies      │ updateRoot(newRoot, proof)  activeRoot ← newRoot  [proof vs tree]
 │ setUpgradeRoot(tree)       use it instantly  │ (only roots are per-proxy; impl needs no per-proxy action)
 ▼                                              ▼
┌──────────────────────────────┐   beacon /   ┌─────────────────────────────┐
│ CounterfactualBeacon (beacon)     │   proof      │ Counterfactual BeaconProxy  │
│  implementation : addr       │ ◄─────────── │  every call: resolve impl   │
│  upgradeRoot : (proxy,root)  │              │   from beacon, then delegate│
│  (admin-curated)             │              │  updateRoot: verify proof   │
└──────────────────────────────┘              └─────────────────────────────┘
```

Because the impl runs under **delegatecall**, `address(this)` is the proxy — it holds the funds, is
`msg.sender` to the bridge, and uses the pinned `finalRecipient` for the bridge's native recipient
field. The destination is a plain bridge fill / mint / compose; no Gateway or destination machinery is
involved.

---

## Address Determinism (same address across chains)

A proxy's address is `f(factory, proxy creation bytecode, salt, init args)`. The meaningful per-user
input is **`initialRoot`**, which is passed in the proxy's init code and written to the `activeRoot`
storage slot on initialization. The CREATE2 **`salt` is fixed to `0`**, so a given `initialRoot`
resolves to exactly one address — one address per destination identity, no vanity/duplicate variants.

For the address to match across chains, every input must be chain-invariant — in particular,
`initialRoot` must be **identical on every chain**. The routes a deposit uses, however, are
source-chain-specific (Arbitrum deposits use Arbitrum's SpokePool, Base deposits use Base's, etc.). We
reconcile this by having `initialRoot` commit a tree that **contains the routes for all source
chains** to the one destination identity. On any given source chain, the relayer proves the leaf
matching that chain's route; the root is the same everywhere.

So for a destination identity `(finalRecipient, outputToken, destinationChainId)`:

```
destination identity  ──►  one canonical initialRoot  ──►  one address on every chain
   (the identity is encoded into the leaves of the initialRoot tree, not stored as separate args)
```

The hard rule: **nothing mutable or chain-specific may enter address derivation** — not the live
`activeRoot` (it changes), not the implementation (it changes globally via the beacon), not a per-chain
root. The address commits only `initialRoot` (plus fixed deployment substrate: the factory, the salt,
and the **beacon = `CounterfactualBeacon`**). This indirection is exactly what lets one address keep a stable
identity while its routes and logic are upgraded underneath it.

> A `BeaconProxy`'s init code embeds the **beacon address** (the `CounterfactualBeacon`) and the
> `initialize(initialRoot)` constructor `data` — **not** the implementation. So the implementation
> (the beacon's target) never affects the address and is the **only** piece free to differ per chain.
> The **factory** and the **`CounterfactualBeacon`** (as beacon) must be deployed deterministically at
> identical addresses on every chain (they're in the proxy's init code: `registry(beacon) → proxy
address`). They are permanent constants, never versioned. Compile the counterfactual stack under the
> dedicated `[profile.counterfactual]` (Phase 0) so the creation bytecode is byte-identical.

---

## How the implementation stays out of the address (beacon, no bootstrap)

A plain ERC-1967/UUPS proxy stores the implementation in its own init code, so the implementation would
enter the CREATE2 preimage. A **`BeaconProxy`** instead stores only the **beacon** address and resolves
the implementation from it **live on every call** — so the implementation is never in the proxy's code
or address, and there is **no bootstrap and no finalize step**:

```solidity
new BeaconProxy{ salt: 0 }(BEACON, abi.encodeCall(CounterfactualDeposit.initialize, (initialRoot)))
// BEACON = the CounterfactualBeacon. Preimage = f(factory, 0, BeaconProxy.creationCode, BEACON, initialRoot)
// ⇒ address = f(initialRoot); the implementation (beacon target) is never in it.
```

The beacon is the **`CounterfactualBeacon`** (it implements `IBeacon.implementation()`). Setting the
registry's `implementation` retargets **every** proxy instantly — implementation upgrades are global and
free of per-proxy action (see _Upgrade Mechanism_). The `initialize(initialRoot)` in the constructor
`data` writes `activeRoot` into the proxy's ERC-7201 storage; because that
`data` is part of the init code, `initialRoot` is bound into the address. The implementation reads/writes
that storage under delegatecall (`address(this)` = proxy); every implementation version must preserve the
ERC-7201 layout.

---

## The Counterfactual's Own Merkle Tree (`activeRoot`)

This is the deposit-authorization tree — same leaf encoding as the base system:

```
leaf = keccak256( bytes.concat( keccak256( abi.encode(implementation, keccak256(params)) ) ) )
```

Two kinds of leaves:

### Route leaves (one per source-chain route)

Each names a **bridge-specific implementation** and a route-specific `params`:

```
implementation = CounterfactualDepositSpokePool | CounterfactualDepositCCTP | CounterfactualDepositOFT
params         = sourceChainId + bridge target + input token + fee caps + quote params + destination identity
```

Because `initialRoot` must be identical across chains, the tree holds one route leaf **per source
chain** (and per bridge, and per input token) for this destination identity — e.g. "from Arbitrum via
SpokePool", "from Base via CCTP", "from Optimism via OFT". At execution the caller proves the leaf for
the chain it's on, and the impl **requires `block.chainid == params.sourceChainId`** — without it, the
shared all-chains tree would let a leaf authored for one chain be proven on another (every leaf is
provable everywhere). A distinct input token on the same source chain is its own leaf; the impl sweeps
that leaf's input token (native ETH via the `NATIVE_ASSET` sentinel, where the bridge supports it).

The recipient is **not** chosen at runtime: this counterfactual is specific to one destination
identity (it's baked into `initialRoot`), so `finalRecipient` is fixed and is injected into the
bridge's native recipient field by the impl. (This differs from a shared-policy model — there is no
recipient-genericity here; each identity gets its own proxy and its own tree.)

### Withdraw leaf (≥1)

```
leaf = keccak256(…(WithdrawImplementation, keccak256(withdrawParams)))
```

The escape hatch (`AdminWithdrawManager` / `WithdrawImplementation`) to sweep stranded balances or
deprecated routes via the same dispatch path. `signedWithdraw` forces payout to the committed user.
This is a plain transfer (no bridge), so rescue always works. Withdraw is **authorization-gated** (the
leaf commits the permitted withdrawer) — **not permissionless** — so it can't be used to grief
in-flight deposits by sweeping funds to the source-chain refund path before they're bridged (see Open
Questions #8).

`initialRoot` is just this tree at deploy time; after an upgrade, `activeRoot` may commit a different
tree (more/updated routes), while the address — fixed by `initialRoot` — is unchanged.

---

## Upgrade Mechanism (`CounterfactualBeacon` + executor)

Upgrades are governed by the global registry, not by a per-proxy admin. The two mutable knobs are
administered differently, along the "shared vs. per-proxy" split:

- **`CounterfactualBeacon`** — one global contract per chain, with an **admin** (the only admin in the
  system) maintaining:
  - `implementation` — the canonical implementation **all** proxies run (the beacon target; shared logic).
  - `upgradeRoot` — the root of an **upgrade merkle tree** of `(proxy, latestRoot)` leaves, authorizing
    per-proxy **root** updates.

Root updates are **best-effort**: a proxy keeps its `activeRoot` until someone calls `updateRoot`; there
is no version counter and no execute-time freshness gate. (The admin therefore cannot _force_ a stale
proxy off an old route set on-chain — to kill a route everywhere, change the implementation via the
beacon, which is global and immediate; see _Open Questions_.)

### Implementation — global, via the beacon (instant)

Implementation is shared logic, so it is administered **once, globally**: the admin calls
`setImplementation(impl)` on the registry (the beacon). Because every counterfactual is a `BeaconProxy`
that resolves `beacon.implementation()` **live on each call**, all proxies use the new implementation
**immediately** — there is **no per-proxy upgrade, no `syncImplementation`, and no bootstrap**. The
registry validates the target is a contract (`NotAContract`); the admin is trusted (and timelocked-by-
intent, D19) since setting it instantly retargets every proxy.

### Root — per-proxy, proof-gated

Each proxy's `activeRoot` is unique (it encodes that identity's routes), so root updates are
**per-proxy**, authorized by the upgrade tree:

```
leaf = keccak256( abi.encode( proxyAddress, latestRoot ) )
```

An executor calls `proxy.updateRoot(newRoot, proof)`; the proxy recomputes
`leaf = keccak256(abi.encode(address(this), newRoot))`, verifies `proof` against
`CounterfactualBeacon.upgradeRoot()`, and on success sets `activeRoot = newRoot` — only the **exact** value
the leaf commits. There is no admin check on the proxy; the root update is gated **solely** by the
registry proof.

> **How the proxy knows the registry.** Two ways, both pointing at the same `CounterfactualBeacon`: (1) the
> `BeaconProxy` stores the registry as its **beacon** (it's the beacon address baked into the proxy at
> construction — and thus in the address), used to resolve the implementation each call; and (2) the
> implementation embeds the registry as an **immutable** (for `updateRoot`'s `upgradeRoot` lookup). The
> registry is a global per-chain constant, deployed deterministically
> at the same address on every chain. If it ever must be replaced, the implementation's immutable would
> change (a new impl pointing at the new registry, set as the beacon target); existing proxies' _beacon_
> is fixed at construction, so replacing the registry effectively means a new proxy generation — a
> deliberate, heavyweight migration.

---

## How Calldata Is Constructed (injection)

Route-related values come from the **route leaf's `params`** (authenticated by the merkle proof against
`activeRoot` — the leaf is the single source, nothing is cross-checked against separate state).
Per-execution values come from `submitterData`, authorized by the `signer` (see _Execution Fees_).

1. **Per-bridge calldata shape** — committed in the route leaf's `params`; the `activeRoot` commits it.
2. **`finalRecipient`, `outputToken`, `destinationChainId`** — the destination identity, decoded from
   `params` and used directly: `finalRecipient` goes into the bridge's **native recipient field**
   (`depositV3` recipient, CCTP `mintRecipient`, OFT `to`); `outputToken` / `destinationChainId` are
   set on the bridge call.
3. **`sourceChainId`** — committed in `params`; the impl requires `block.chainid == params.sourceChainId`
   so a leaf can't be replayed on the wrong chain (the all-chains tree is identical everywhere).
4. **`inputAmount` / `outputAmount` / `executionFee`** — supplied in `submitterData` and **authorized by
   the `signer`** (bound in the EIP-712 fee signature for SpokePool; via the periphery quote signature
   for CCTP/OFT — see _Execution Fees_). The deposit bridges `inputAmount − executionFee`; the fee is
   bounded by the leaf cap. This is **not live balance** — the amount is signed, so the `f(inputAmount)`
   fee cap and the (caller-chosen) `executionFeeRecipient` can't be gamed. (Matches the
   `taylor/counterfactual-route-policy` branch.)

The destination is a native bridge fill / mint / compose to the recipient — no extra destination
delivery mechanism.

---

## Execution Fees (dynamic, signed)

All three bridge implementations (`CounterfactualDepositSpokePool` / `CounterfactualDepositCCTP` /
`CounterfactualDepositOFT`) **must** support a **dynamic execution fee** chosen at execution time by
the submitter: the fee is paid in the input token to an `executionFeeRecipient`, and only
`amount − executionFee` is bridged. Because the fee is not committed in the route leaf, it must be
**authorized by an off-chain `signer` and verified on-chain**. We reproduce the scheme used on the
`taylor/counterfactual-route-policy` branch verbatim so off-chain quoting/tooling stays compatible.

Mechanism (identical across the three impls):

- Each impl is an **`EIP712`** contract (`name = "CounterfactualDeposit<Bridge>"`,
  `version = "v2.0.0"`) with an immutable **`signer`** set at construction. Under delegatecall the
  EIP-712 domain's `verifyingContract` resolves to `address(this)` = the **counterfactual proxy**, so a
  signature is bound to one proxy and cannot be replayed against another.
- `submitterData` carries the runtime `executionFee`, a `signatureDeadline`, and a
  `counterfactualSignature` (the fee authorization). `_verifySignature` reverts `SignatureExpired` if
  `block.timestamp > signatureDeadline`, then requires
  `ECDSA.recover(_hashTypedDataV4(structHash), counterfactualSignature) == signer` (else
  `InvalidSignature`).
- The route leaf commits an **upper bound** on the fee, checked _after_ verification:
  `maxExecutionFee` for CCTP/OFT, or the combined `maxFeeFixed + maxFeeBps × inputAmount` cap for
  SpokePool (which bounds the implicit relayer fee + execution fee together via `_checkFee`).
- Native-token deposits (SpokePool) pay the fee via a `call{value: executionFee}`; ERC-20 deposits via
  `safeTransfer`.

Per-bridge typehash and binding:

| Impl          | EIP-712 typehash                                                                                                                                                                                                                             | Route / amount binding                                                                                                                                                                                             |
| ------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **SpokePool** | `ExecuteDeposit(address clone,bytes32 routeParamsHash,uint256 inputAmount,uint256 outputAmount,bytes32 exclusiveRelayer,uint32 exclusivityDeadline,uint32 quoteTimestamp,uint32 fillDeadline,uint32 signatureDeadline,uint256 executionFee)` | Binds **everything explicitly** — `clone`, `routeParamsHash`, and all runtime fields — because there is no separate periphery quote signature.                                                                     |
| **CCTP**      | `ExecuteCCTP(bytes32 nonce,uint256 executionFee,uint32 signatureDeadline)`                                                                                                                                                                   | Clone bound via the domain; amount/route bound **transitively** through the periphery quote signature (which commits `(route, nonce)`); `nonce` gives single-use replay protection once the periphery consumes it. |
| **OFT**       | `ExecuteOFT(bytes32 nonce,uint256 executionFee,uint32 signatureDeadline)`                                                                                                                                                                    | Same as CCTP.                                                                                                                                                                                                      |

> CCTP and OFT additionally forward a **separate periphery quote signature** (`peripherySignature`) to
> the sponsored-bridge periphery unchanged — **two signatures per execute**. SpokePool calls
> `SpokePool.deposit` directly (no periphery), so it has only the one EIP-712 fee signature and
> therefore must bind the clone, route hash, and all runtime fields in its own typehash.

> Note for the upgradeable model: the impl is reachable via UUPS upgrade, so its constructor-immutable
> `signer` lives in the implementation bytecode. For cross-chain address parity the implementation must
> be deployed deterministically (Phase 0/5), which also keeps `signer` consistent across chains.

---

## Trust Model

- The **depositor** trusts the route set baked into `initialRoot`, and trusts the `CounterfactualBeacon`
  admin to authorize only safe upgrades for their proxy.
- The **`CounterfactualBeacon` admin** is the system's only admin: it sets the global `implementation` (the
  beacon target) every proxy runs, and curates the `(proxy, latestRoot)` tree that authorizes per-proxy
  root updates. Use `Ownable2Step` + multisig. This role is **effectively all-powerful over funds**:
  setting the beacon `implementation` to a malicious/buggy contract **instantly** retargets every proxy
  (they resolve it live), and that impl runs with each proxy's balance. A **timelock** would give users
  a window to withdraw before a new implementation takes effect, but is **omitted in this implementation
  (D19)** — a known residual risk, mitigated only by trusting the multisig admin. (Revisit if a timelock
  is wanted later — note a beacon makes upgrades immediate, so a timelock matters _more_ here.)
- The **executor** is untrusted and permissionless: it can only apply a root the registry's tree already
  authorizes (exact leaf value) — it chooses neither the implementation (beacon-set) nor the root.
- The **per-bridge implementations** have full delegatecall power in the proxy's frame — the trusted
  code to audit. A proxy can only ever run the implementation the registry admin set as the beacon target.
- The **execution-fee `signer`** is trusted to authorize only fair runtime `executionFee` values
  (bounded by the leaf cap). It cannot redirect funds — the recipient is the pinned identity — only
  attest to the fee; an unsigned or expired fee reverts.
- The **relayer** is untrusted: it can only move the proxy's funds to the pinned `finalRecipient` via
  an authorized route.

---

## Differences From the Base Counterfactual

| Aspect                       | Base (immutable)                                  | Upgradeable (this design)                                                                      |
| ---------------------------- | ------------------------------------------------- | ---------------------------------------------------------------------------------------------- |
| Proxy type                   | EIP-1167 minimal clone                            | ERC-1967 **`BeaconProxy`** (beacon = `CounterfactualBeacon`); no bootstrap                     |
| Route root                   | Immutable clone arg                               | Mutable **`activeRoot`** storage (init from `initialRoot`)                                     |
| Implementation               | Fixed dispatcher                                  | **Global** beacon target; not in the address; resolved live per call                           |
| Who can change impl          | No one                                            | Admin only, via `registry.setImplementation` → **all** proxies instantly (no per-proxy action) |
| Who can change routes (root) | No one                                            | Permissionless **executor** with a proof vs the registry's `(proxy, latestRoot)` tree          |
| Admin                        | None                                              | None on the proxy; the **`CounterfactualBeacon`** has the only admin                           |
| Cross-chain address          | Differs (root is chain-specific)                  | **Same** (`initialRoot` identical; all-source-chains tree)                                     |
| Deposit dispatch             | Merkle proof vs root                              | **Same**, but proof is vs `activeRoot` in storage                                              |
| Per-bridge impls             | `CounterfactualDeposit{CCTP,OFT,SpokePool}`       | **Same**, reused as leaf implementations                                                       |
| Withdraw / rescue            | `AdminWithdrawManager` + `WithdrawImplementation` | **Same**, as the withdraw leaf                                                                 |

---

## Implementation Plan

### Phase 0 — Counterfactual build profile ✅ (profile in place)

`[profile.counterfactual]` already exists in `foundry.toml`: `src = contracts/periphery/counterfactual`,
`script = script/counterfactual`, isolated `out-counterfactual` / `cache-foundry-counterfactual`, and
**`bytecode_hash = "none"`** (strips the metadata hash so creation bytecode — and thus CREATE2
addresses — stays stable across commits and chains). Build/deploy with `FOUNDRY_PROFILE=counterfactual`.

The determinism-critical set that needs byte-identical bytecode is the **factory** and the
**`CounterfactualBeacon`** (the beacon) — they fix proxy addresses via `registry(beacon) → proxy`; the
**implementation does not** (it is in no address). The profile _config_ is done, but the contracts it
will build are new (Phases 1–2). Remaining Phase-0 work: pin a fixed solc/optimizer combination for
those contracts and add a `forge inspect <c> bytecode` cross-chain parity check once they exist.

### Phase 1 — Counterfactual proxy (BeaconProxy) + implementation ✅ DONE (contracts compile)

These **replace** the old immutable counterfactual contracts, reusing their names (D21). All live in
`contracts/periphery/counterfactual/`:

- **`CounterfactualDeposit`** — the single implementation (the registry/beacon's `implementation()`). It
  owns the proxy's ERC-7201 storage (`activeRoot`) and the immutable `BEACON`, and provides:
  `initialize(initialRoot)` (run via the `BeaconProxy` constructor `data`, writing `activeRoot`); the
  merkle dispatcher `execute(implementation, params, submitterData, proof)` (verifies vs `activeRoot`,
  then delegatecalls `ICounterfactualImplementation.execute` — no version gate); permissionless
  `updateRoot(newRoot, proof)`. Implements `ICounterfactualDeposit`. **No UUPS / no `syncImplementation`**
  — the implementation is the beacon target, always current. (There is no separate base contract —
  `CounterfactualBase` was folded in.)
- **`CounterfactualDepositFactory`** — deterministic CREATE2 deployment of
  `BeaconProxy(BEACON = registry, initialize(initialRoot))` at salt 0 (no finalize); `predictAddress` /
  `deploy` / `deployAndExecute` / `deployIfNeededAndExecute`. `predictAddress` / `_initCode` /
  `_computeProxyAddress` are `virtual` for a Tron override (Q12).

> No `CounterfactualBootstrap` — the beacon makes the implementation always-current with no bootstrap.
> The old immutable-system tooling (its tests + deploy scripts) is **superseded and currently left
> broken** — rebuilt in Phase 4 (tests) / Phase 5 (deploy).

### Phase 2 — CounterfactualBeacon (the beacon) + upgrade path

- **`CounterfactualBeacon`** — global per-chain contract and **`IBeacon`** for every proxy: admin-settable
  `implementation` (the beacon target every proxy runs; `setImplementation` requires a contract) and
  `upgradeRoot` (the `(proxy, latestRoot)` tree). `Ownable2Step` + multisig (timelock omitted — D19).
  **Itself a UUPS proxy** (Q11). Deployed deterministically (same address per chain — required, since
  every `BeaconProxy` embeds it as the beacon).
- **`updateRoot(newRoot, proof)`** on the proxy — recompute `leaf = keccak(this, newRoot)`, verify
  against `CounterfactualBeacon.upgradeRoot()`, set `activeRoot`. No admin check; best-effort (no version gate).
- **No per-proxy implementation upgrade** — impl changes are global via `registry.setImplementation`.

### Phase 3 — Per-bridge route implementations ✅ DONE (impls compile)

The three impls were updated by porting the **signed dynamic `executionFee`** scheme from the
`taylor/counterfactual-route-policy` branch (EIP-712 `signer` + `counterfactualSignature` +
`signatureDeadline`, leaf fee cap via `maxExecutionFee`, a separate forwarded periphery `signature` for
CCTP/OFT, EIP-712 `v2.0.0`), while keeping our **identity-in-`params`** model (2-arg `execute`, identity
decoded from `params`, no `CloneIdentity.enforce`) and adding the **`sourceChainId` + `block.chainid`
check** (D15). The route-params structs are named `*RouteParams` with descriptive locals
(`routeParams` / `submitterData`, calldata `routeParamsEncoded` / `submitterDataEncoded`); pre-existing
comments are otherwise left untouched to keep the audit diff to functional changes only. The identity
stays in the params struct (`(final)recipient`, `outputToken`, `destinationChainId`). The withdraw leaf
reuses `AdminWithdrawManager` / `WithdrawImplementation`
unchanged (authorizer committed in the leaf — Q8/D12). The Tron variants still compile with the same
constructors as their parents and override `_safeTransfer` only.

> Spec (kept for reference): start from the base `CounterfactualDeposit{SpokePool,CCTP,OFT}` impls,
> which already decode the route
> and destination identity (`finalRecipient`, `outputToken`, `destinationChainId`) straight from the leaf
> `params` (authenticated by the proof — there is no separate identity to cross-check against). Each
> requires `block.chainid == params.sourceChainId`, injects `finalRecipient` into the bridge's native
> field, bridges `inputAmount − executionFee` (amount from signed `submitterData`, not live balance), and
> must implement the **dynamic signed `executionFee`** scheme (see
> _Execution Fees_): `EIP712` + immutable `signer`, `_verifySignature` over the per-bridge typehash, leaf
> fee cap, and fee payout to `executionFeeRecipient` — matching the `taylor/counterfactual-route-policy`
> branch. Add the route leaves (SpokePool, CCTP, OFT) plus the withdraw leaf.

### Phase 4 — Tests

Written **after all contract changes are done** (Phases 1–3), as one consolidated suite rather than
per-phase:

- **Proxy / factory** — `initialRoot → activeRoot` init via the `BeaconProxy` constructor; deploy →
  deposit dispatch; cross-chain address determinism (same `initialRoot` ⇒ same address, independent of
  the implementation); a proxy resolves the impl from the beacon (set `registry.implementation` then
  confirm `execute` runs the new logic with no per-proxy action).
- **CounterfactualBeacon / upgrades** — `setImplementation` retargets all proxies at once; `updateRoot` via
  proof; rejection of an unproven/forged root leaf; rejection once the registry root rotates (stale leaf
  invalid); no-op root (`newRoot == activeRoot`) reverts.
- **Per-bridge verticals (SpokePool, CCTP, OFT)** — happy-path deposit per bridge; `block.chainid !=
sourceChainId` rejection; valid / expired / forged fee signatures; over-cap fee rejection; native-ETH
  path where supported; the withdraw leaf (authorized vs. unauthorized).

### Phase 5 — Deployment

Deterministically deploy the **factory** and the **`CounterfactualBeacon`** (the beacon) at identical
addresses across chains (under `FOUNDRY_PROFILE=counterfactual`); deploy the `CounterfactualDeposit`
implementation per chain and `registry.setImplementation(it)`. Publish the route trees and the initial
upgrade tree. Verify same-address parity across chains (independent of the implementation). Record
addresses in the generated address artifacts.

---

## Open Questions

1. **Factory / registry (beacon) determinism.** Cross-chain address parity requires the **factory** and
   the **`CounterfactualBeacon`** (the beacon) to be at identical addresses on every chain (`registry(beacon)
→ proxy`). Lock this with deterministic deployment + the byte-identical profile (Phase 0). The
   implementation (the beacon target) need not be deterministic for parity (it's in no address), though
   it's still deployed deterministically for operational simplicity.
2. **Pre-deployment ordering.** An address can receive funds before its proxy is deployed.
   `deployIfNeededAndExecute` deploys the `BeaconProxy` (already initialized + always-current via the
   beacon) and executes in one tx. A freshly deployed proxy starts at `initialRoot`; a route upgrade only
   applies after a later `updateRoot`. Confirm this ordering is acceptable.
3. ~~**Root replay / monotonicity.**~~ **RESOLVED (D25): no contract change.** Implementation is always
   current (beacon-resolved). For **roots**, downgrade is
   prevented off-chain: registry-root **rotation** invalidates old trees' proofs, and the tree
   generator must enforce **at most one `(proxy, root)` leaf per proxy** per tree. Residual risk
   accepted: a tooling slip (duplicate/stale leaf) would be attacker-exploitable via the permissionless
   `updateRoot` — so the one-leaf-per-proxy invariant is a hard, tested requirement of the tree builder.
4. **`CounterfactualBeacon` admin controls.** `Ownable2Step` + multisig from the start (timelock omitted in
   this implementation — D19); it is the only privileged role — it sets the global `implementation`
   (the beacon target, used by all proxies instantly) and curates the per-proxy root tree.
5. **Implementation storage-layout safety.** Every implementation the beacon points to must preserve the
   ERC-7201 `activeRoot` storage layout (the proxy's storage). Add layout checks/tests; a bad impl set as
   the beacon target would corrupt every proxy at once.
6. ~~**`AdminWithdrawManager` replay.**~~ **RESOLVED (D24): accepted as-is.** `signedWithdraw` is
   replayable within its deadline (no nonce/used-marking) — a conscious decision, since the payout is
   forced to the committed user, so replays only re-pay the rightful user.
7. **Admin actions via the counterfactual's own tree.** Beyond deposits/withdraws, decide whether any
   other privileged actions should be expressible as leaves in a proxy's `activeRoot` tree (vs. routed
   exclusively through the `CounterfactualBeacon`).
8. ~~**Withdraws — what authorization, and is an admin needed?**~~ **RESOLVED (D12).** Withdraw is
   authorization-gated, not permissionless: `WithdrawImplementation` requires `msg.sender` to equal the
   `{admin, user}` committed in the leaf params (authenticated by the proof) — reused from v4 unchanged.
   `user` = self-rescue (picks any `to`); `admin` = `AdminWithdrawManager` (assisted rescue, forces
   payout to `user` on the signed path). The specific `user`/`admin` addresses are an **off-chain
   tree-config choice** (and, being leaf values, are part of the address) — not an open contract
   question. (Permissionless withdraw was rejected as a DoS vector; `signedWithdraw` replay accepted —
   D24.)
9. ~~**Should being up-to-date be required to execute?**~~ **RESOLVED (D28): no.** Implementation
   freshness is automatic (beacon-resolved — D27); **root** freshness is **not** enforced — root updates
   are best-effort (a proxy keeps its `activeRoot` until updated). The version/min-version gate was added
   (D13) then removed (D28). To kill a route everywhere, change the implementation via the beacon (global).
10. ~~**Version counters on `CounterfactualBeacon` and the proxy.**~~ **RESOLVED (D28): none.** No `version` /
    `minRequiredVersion` on the registry, no `rootVersion` on the proxy. (Adopted briefly in D13, removed
    in D28.) Impl freshness is automatic via the beacon (D27).
11. ~~**Is the `CounterfactualBeacon` itself upgradeable?**~~ **RESOLVED (D19): yes — UUPS proxy, no
    timelock in this implementation.** It must have a permanent address anyway (every `BeaconProxy`
    embeds it as the beacon, anchoring proxy addresses via `registry(beacon) → proxy`), so a UUPS proxy
    keeps the address fixed while its logic can evolve. Upgradeability doesn't widen the trust surface
    (the admin is already all-powerful — setting the beacon `implementation` instantly retargets every
    proxy); the dropped trade-off is that the registry's rules are no longer immutable.
12. **Tron support.** Tron is **in scope (D18)**. **Resolved:** Tron addresses need **not** match the
    EVM addresses — a Tron deposit address is its own thing. So Tron gets a **separate Tron factory**
    (mirroring the base `CounterfactualDepositFactoryTron`) and **Tron-specific implementations where
    needed** — principally the USDT / `safeTransfer` issue (Tron USDT doesn't return a bool, so use the
    `SafeTransferERC20` / `TronTransferLib` pattern). The **Tron factory is reworked**:
    `CounterfactualDepositFactoryTron` now extends the `BeaconProxy`-based factory and overrides only
    the `_computeProxyAddress` hook to predict with Tron's 0x41 prefix (`TronClones.computeAddress`);
    deployment via `deploy()` uses the native `create2` (0x41) so it works as-is.

    **Remaining open — "compiles ≠ runs on the TVM" (validate on a Tron testnet before investing
    further), roughly by severity:**
    - **(a) Cancun/Shanghai opcodes the compiler emits.** The `tron` profile uses
      `evm_version = "cancun"`, so `solc 0.8.25` may emit **`MCOPY`** (memory copies — our impls do many
      via `abi.decode` of structs with dynamic `bytes` fields + struct copies) and **`PUSH0`**. If the
      TVM doesn't implement these, contracts revert at runtime despite compiling. (We do **not** use
      `TLOAD`/`TSTORE`.) Action: confirm TVM cancun support, or lower the tron profile's `evm_version`.
    - **(b) `block.chainid`.** Used by the D15 `sourceChainId` check **and** the EIP-712 domain. Confirm
      the TVM `CHAINID` opcode returns a stable known value, and that Tron leaves' `sourceChainId` + the
      off-chain signer's EIP-712 chainId both equal it — else every deposit reverts.
    - **(c) Deterministic deployment of the substrate.** Tron lacks the standard EVM CREATE2 deployer;
      decide how the factory / `CounterfactualBeacon` reach known Tron addresses (so prediction is meaningful),
      and deploy the registry on Tron.
    - **(d) Beacon / ERC-1967 semantics.** Conceptually fine (TVM has `delegatecall`, `EXTCODESIZE`, the
      ERC-1967 beacon slot) but unproven: `BeaconProxy` construction (which reads `beacon.implementation()`
      and the `ERC1967Utils` code-size check) and live impl resolution must be tested on Shasta/Nile.
    - **(e) Native asset (TRX / WTRX).** The SpokePool `NATIVE_ASSET` path wraps to `wrappedNativeToken`
      (WTRX on Tron, 6-decimal TRX) — needs Tron-specific config, or disable native for Tron routes.
    - **Already handled:** 0x41 CREATE2 prefix (factory override); USDT non-standard `transfer` return
      (the `_safeTransfer` hook in the Tron route/withdraw variants); `ecrecover` (works, given the
      signer signs with Tron's chainId per (b)).

13. ~~**Beacon proxy instead of UUPS + bootstrap?**~~ **RESOLVED (D27): adopted — OZ `BeaconProxy`,
    registry as beacon.** The `BeaconProxy` eliminates the bootstrap, `syncImplementation`, the finalize
    step, and the impl-staleness gate — proxies run the current impl by construction. We accepted OZ's
    stock `BeaconProxy` (~287-byte runtime ≈ +37k gas/deploy) over a minimal custom / Solady proxy (would
    erase the cost but adds a dependency + binding plumbing). Impl upgrades are now immediate/global; the
    per-proxy `minRequiredVersion` root gate (D13) remains. Revisit the proxy flavor (minimal/Solady)
    only if per-deploy cost becomes a priority — it's isolated to the factory's init code.

---

## Design Decisions

Decisions made so far, with reasoning. (Kept up to date as we decide things; provisional / "for now"
calls are marked and cross-referenced to the relevant Open Question.)

- **D1 — Upgradeable proxy with in-storage root; no `RoutePolicy`.** Each counterfactual is its own
  ERC-1967 UUPS proxy storing `activeRoot`. _Why:_ routes and logic must be upgradeable without changing
  the user-facing address; an in-storage root indirected from the immutable address achieves this, and a
  separate policy contract is unnecessary indirection.
- **D2 — Direct per-bridge bridging, native recipient; no Gateway.** Bridging is done by per-bridge
  delegatecall impls (`CounterfactualDeposit{SpokePool,CCTP,OFT}`) that call the bridge directly and put
  `finalRecipient` in the bridge's native recipient field. _Why:_ simplest path, reuses the existing
  audited impls, and the destination is handled by the bridge itself — no Gateway/Executor/planner/
  Shape-A machinery (the earlier v5 generalization, dropped).
- **D3 — No admin on the proxy.** Deposits/withdraws are authorized by the proxy's own `activeRoot` tree;
  upgrades by the global `CounterfactualBeacon`. _Why:_ removes a per-proxy trusted key and concentrates the
  single trust point in the registry.
- **D4 — Address = `f(initialRoot)`; identity baked into the tree.** `initialRoot` (in init code, written
  to `activeRoot`) commits a tree carrying every source chain's route to one destination identity
  `(finalRecipient, outputToken, destinationChainId)`. _Why:_ identical `initialRoot` on every chain ⇒
  same address everywhere for a destination identity; per-chain routes differ but share one root (the
  caller proves the leaf for its chain).
- ~~**D5 — Bootstrap deployment keeps the real impl out of the address.**~~ **Superseded by D27
  (beacon).** The `BeaconProxy` keeps the implementation out of the address with no bootstrap.
- ~~**D6 — Finalize via global `currentImplementation()`, no proof.**~~ **Superseded by D27 (beacon).**
  There is no finalize step — the beacon resolves the implementation live.
- **D7 — Implementation is global; roots per-proxy.** Implementation is administered once globally (the
  beacon's `implementation`; D27) — set by the admin, used by all proxies instantly. Roots are per-proxy
  via `updateRoot(newRoot, proof)` against the registry's `(proxy, latestRoot)` tree; the leaf carries
  **no** implementation. _Why:_ implementation is shared logic; roots are inherently per-proxy (each
  encodes a unique identity's routes). _Rejected:_ a per-proxy impl override for canary/staggered rollout.
- **D8 — Registry handle is immutable in impl bytecode (and the proxy's beacon).** The `CounterfactualBeacon`
  address is an immutable in `CounterfactualDeposit` (for `updateRoot`/the version gate) **and** the
  `BeaconProxy`'s beacon (for live impl resolution). Not per-proxy state. _Why:_ it's a global per-chain
  constant; storing it per-proxy would waste an `SSTORE`/`SLOAD` and bloat init code.
- **D9 — Factory + registry (beacon) are same-address on every chain.** _Why:_ the `BeaconProxy` embeds
  the registry as its beacon, and is deployed by the factory, both in the proxy preimage
  (`registry(beacon) → proxy`), so both must be chain-invariant for address parity. (The implementation —
  the beacon target — is the only piece exempt.)
- **D10 — Dynamic, signed execution fees on all three impls.** Each impl accepts an `executionFee` from
  `submitterData`, authorized by an EIP-712 signature from an immutable `signer` and bounded by a
  leaf-committed cap — matching the `taylor/counterfactual-route-policy` branch. _Why:_ compensates the
  submitter with a fee quoted at execution time without committing it in the route leaf, while bounding
  it and preventing forgery.
- **D11 — Destination identity lives only in the tree (not pinned).** `(finalRecipient, outputToken,
destinationChainId)` exists only in the `activeRoot` leaves; impls decode and use it, authenticated by
  the proof — no separate storage, no cross-check. _Why:_ simplicity. _Trade-off accepted:_ the recipient
  is mutable via an authorized root update (within the all-powerful-admin trust assumption). _Rejected:_
  pinning the identity (route-policy `CloneIdentity` model).
- **D12 — Withdraws are authorization-gated, not permissionless.** _Why:_ a permissionless withdraw to
  the pinned recipient is a DoS/griefing vector — anyone could sweep funds to the source-chain refund
  path before a deposit is bridged. _For now:_ keep `AdminWithdrawManager`, and the authorizer / refund
  address live **only in the merkle tree** (never proxy state), per the in-tree model (D11). Exact
  committed `{admin, user}` are an off-chain tree-config choice (Q8, resolved). (`signedWithdraw`
  replayability accepted as-is — D24.)
- ~~**D13 — `execute` requires the proxy's root to be recent enough.**~~ **Reversed by D28.** The
  `version` / `minRequiredVersion` / `rootVersion` gate was added here, then removed — root updates are
  best-effort, no execute gate.
- ~~**D26 — Fresh proxy stamped at the registry's current `version` on deploy.**~~ **Obsolete (D28).**
  No `rootVersion` to stamp; `initialize` just writes `activeRoot`.
- **D14 — Amounts come from signed `submitterData`, not live balance.** `inputAmount` / `outputAmount` /
  `executionFee` are supplied per-execution in `submitterData` and authorized by the `signer` (EIP-712
  for SpokePool; periphery quote sig for CCTP/OFT), matching the `taylor/counterfactual-route-policy`
  branch. The deposit bridges `inputAmount − executionFee`. _Why:_ the fee cap is `f(inputAmount)` and
  the `executionFee` goes to a caller-chosen recipient, so the amount must be authorized — a free/live
  amount could be used to inflate the cap and drain via the fee. (Supersedes the earlier "live balance"
  wording, a leftover from the dropped V5 `BalanceSub` idea.)
- **D15 — Source-chain binding in route leaves.** `params` commits `sourceChainId`; the impl requires
  `block.chainid == params.sourceChainId`. _Why:_ `initialRoot` is the same all-source-chains tree on
  every chain, so every leaf is provable everywhere — the check stops a leaf authored for one chain
  being used on another.
- **D16 — CREATE2 `salt` fixed to `0`.** _Why:_ makes the address purely `f(initialRoot)` — one
  destination identity ⇒ exactly one address, no vanity/duplicate variants.
- **D17 — `execute(params, submitterData)` impl interface.** The dispatcher is
  `execute(implementation, params, submitterData, proof)`; impls implement
  `ICounterfactualImplementation.execute(params, submitterData)` and decode identity from `params`
  (base-branch shape). _Why:_ identity is in-tree (D11), so no identity args are needed — avoids the
  route-policy 6-arg form.
- **D18 — Tron is in scope; Tron addresses need not match EVM.** A separate **Tron factory** (mirroring
  `CounterfactualDepositFactoryTron`) and **Tron-specific impls where needed** (notably the USDT /
  `safeTransfer` issue → `SafeTransferERC20` / `TronTransferLib`). _Why:_ Tron's create2/address format
  and solc fork differ; cross-Tron↔EVM parity isn't required, so a parallel Tron track is simpler than
  forcing one address scheme. Details tracked in Q12.
- **D19 — `CounterfactualBeacon` is upgradeable (UUPS); no timelock in this implementation.** It needs a
  permanent address anyway (every `BeaconProxy` embeds it as the beacon), so a UUPS proxy keeps the
  address fixed while logic can evolve. _Why no timelock:_ explicit scope decision for this first
  implementation — accepting that the admin is all-powerful (setting the beacon `implementation`
  instantly retargets every proxy) with no on-chain user-exit window. Known residual risk; revisit later
  (note: with the beacon, impl upgrades are immediate, so a timelock matters more). Resolves Q11.
- **D20 — Token model: per-input-token leaves; native via `NATIVE_ASSET`.** A distinct input token on a
  source chain is its own route leaf; the impl sweeps that leaf's input token, with native ETH via the
  `NATIVE_ASSET` sentinel where the bridge supports it — following the
  `taylor/counterfactual-route-policy` branch. EIP-712 domain `version = "v2.0.0"` (same branch).
- **D21 — The upgradeable contracts reuse the immutable names and replace that system.** No new
  `Dispatcher`/`Upgradeable*` contract names: `CounterfactualDeposit` (the single beacon-target
  implementation, which also holds the proxy storage + `updateRoot`) and `CounterfactualDepositFactory`
  (the `BeaconProxy` factory) take over the existing names, alongside `CounterfactualBeacon` (the beacon); all
  in `contracts/periphery/counterfactual/`. _Why:_ this upgradeable design _is_ the counterfactual system,
  not a parallel variant. _Consequence:_ the old immutable-system tests and deploy scripts are superseded
  and **left broken for now**, rebuilt in Phase 4 / Phase 5.
- **D22 — Reject no-op root updates.** `updateRoot` reverts `RootUnchanged` if neither the root nor the
  version would change. _Why:_ avoids redundant state writes / event spam. (The impl no-op guard from the
  UUPS era is gone — there is no per-proxy implementation upgrade under the beacon, D27.)
- ~~**D23 — Keep UUPS + bootstrap; don't switch to a beacon (provisional).**~~ **Reversed by D27.**
- **D27 — Adopt the beacon pattern (OZ `BeaconProxy`); the `CounterfactualBeacon` is the beacon.** Each
  counterfactual is an OZ `BeaconProxy(registry, initialize(initialRoot))`; the registry implements
  `IBeacon.implementation()`. _Why:_ the beacon makes the implementation **always-current** by
  construction — deleting the bootstrap, `syncImplementation`/`_authorizeUpgrade`, and the finalize step.
  (Require-latest via UUPS cost the same per-call registry read as the beacon but added sync friction the
  beacon avoids.)
  _Cost accepted:_ OZ's stock `BeaconProxy` runtime is ~187 bytes larger than `ERC1967Proxy` (≈ +37k
  gas/deploy); chose OZ stock (audited, in-repo, binds `initialRoot`→address for free via constructor
  `data`) over a minimal custom / Solady proxy (would erase the cost but adds a dependency + binding
  plumbing). Resolves Q13; supersedes D5, D6, D23. Trust note: impl upgrades are now immediate-global, so
  a timelock matters more (still omitted — D19).
- **D24 — Accept `AdminWithdrawManager.signedWithdraw` replayability as-is.** No nonce / used-marking;
  the signature is replayable within its `deadline`. _Why:_ the recipient is forced to the committed
  `user`, so a replay can only re-pay the rightful user (not theft); not worth the extra storage/used-map.
  (Was Q6.)
- **D25 — No on-chain root-version monotonicity; rely on an off-chain invariant.** `updateRoot` is
  permissionless and version-less. Downgrade-to-a-retired-root is prevented by (i) registry-root
  rotation invalidating old trees, and (ii) a tree-generator invariant of **≤1 `(proxy, root)` leaf per
  proxy** per tree. _Why:_ the invariant is natural and the admin is already trusted. _Risk accepted:_ a
  tooling slip would let anyone roll a proxy back to a stale root via the permissionless `updateRoot` —
  the tree builder must lint/enforce the invariant. (Was Q3.)
- **D28 — Remove versioning entirely.** No `version` / `minRequiredVersion` on the registry and no
  `rootVersion` on the proxy; `execute` has no root-freshness gate. Root updates are **best-effort** — a
  proxy keeps its `activeRoot` until someone `updateRoot`s it. _Why:_ simpler (smaller registry + proxy,
  one fewer registry read per `execute`); the implementation — which the beacon keeps always-current
  (D27) — is the lever for any must-take-effect-everywhere change, so the route force-upgrade gate wasn't
  worth its weight. _Consequence:_ the admin cannot force a stale proxy off an old route set on-chain;
  retiring a route everywhere is done by changing the implementation (global, via the beacon) or
  disabling the route's periphery, not by a per-proxy version bump. Reverses D13, obsoletes D26.
- **D29 — Rename `UpgradeRegistry` → `CounterfactualBeacon` (interface `IUpgradeRegistry` →
  `ICounterfactualBeacon`); the proxy's immutable handle is `BEACON`.** _Why:_ once versioning was
  removed (D28) and the contract's only role is to be the proxies' `IBeacon` (current `implementation()`
  plus the `upgradeRoot` source), "beacon" names what it is; "registry" overstated a curation role it no
  longer has. Storage namespace moves to `across.counterfactual.beacon.storage`. Pure rename — no
  behavior change. Renames the contract from D27/D19.
