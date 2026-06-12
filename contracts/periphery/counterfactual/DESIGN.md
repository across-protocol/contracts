# Upgradeable Counterfactuals — Design

> **Implementation target: this repo (`across-protocol/contracts`), branch
> `taylor/counterfactual-upgradeable`.** This design supersedes earlier route-policy sketches: there
> is **no `RoutePolicy` contract**. Each counterfactual is a **`BeaconProxy`** that holds its route root
> in storage; the single global **`CounterfactualBeacon`** per chain is its **beacon** (the one shared
> implementation every proxy runs) and governs per-proxy root upgrades.

## Motivation

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
6. **Dynamic, signed execution fees** — all four bridge implementations accept an `executionFee`
   chosen at execution time via `submitterData`, authorized by an off-chain `signer` and verified
   on-chain
7. **Chain-agnostic leaves** — every chain-specific value (bridge endpoints, CCTP domain / OFT EID, the
   fee `signer`, and token addresses) lives on the per-chain `CounterfactualBeacon` as a `public
immutable`. Leaf implementations read those at runtime and name no chain-specific address themselves,
   so a leaf is **byte-identical on every chain** and `initialRoot` carries **one leaf per route**, not
   one per source chain (see _Chain Configuration_ and _Address Determinism_).

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
  **Upgrade Tree** of `(proxy, latestRoot)` leaves. They are best-effort — a proxy keeps its `activeRoot`
  until updated; there is no execute-time version gate.

> **Terminology — the system has exactly two kinds of merkle tree. These names are used throughout:**
>
> - **Route Tree** — _per counterfactual._ Its root is the proxy's `activeRoot` (the `initialRoot` it was
>   deployed with, until upgraded). Leaves are `keccak256(implementation, keccak256(params))` authorizing
>   the per-bridge deposit/withdraw actions that proxy may perform. `execute` proves a leaf against it.
> - **Upgrade Tree** — _per chain._ Its root is the `CounterfactualBeacon.upgradeRoot` on that chain.
>   Leaves are `keccak256(proxy, newRoot)` authorizing each proxy to move its `activeRoot` to a new **Route
>   Tree** root. `updateRoot` proves a leaf against it.
>
> A Route Tree root is therefore a _leaf value_ inside the Upgrade Tree. (The `keccak256(…)` forms above
> are shorthand; both trees use the OpenZeppelin `StandardMerkleTree` double-hash leaf encoding
> `keccak256(bytes.concat(keccak256(abi.encode(…))))` — see the exact formulas below.)

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
storage slot on initialization. The CREATE2 **`salt` is caller-supplied**; passing **`salt = 0`** gives
the canonical one-address-per-destination-identity behaviour (no vanity/duplicate variants). A non-zero
`salt` is allowed and yields additional addresses for the same `initialRoot` — useful when one identity
wants distinct deposit addresses — at the cost of moving cross-chain parity from automatic to a caller
obligation (see below).

For the address to match across chains, every input must be chain-invariant — in particular, both
`initialRoot` **and `salt`** must be **identical on every chain** (`salt = 0` satisfies this trivially).
A route's source-chain specifics (Arbitrum deposits use Arbitrum's SpokePool and Arbitrum USDC, Base
deposits use Base's, etc.) **no longer leak into the leaf**: the leaf implementation reads those values
from the per-chain `CounterfactualBeacon` at runtime, and the token is fixed by the implementation
(`CounterfactualDepositSpokePoolUsdc` → `beacon.usdc()`, etc.), so the leaf names neither the chain nor
the token (see _Chain Configuration_). A leaf is therefore **byte-identical on every chain**, and
`initialRoot` is simply that one tree — **one leaf per route** (bridge × destination identity), not one
leaf per source chain. The same `initialRoot` is trivially identical everywhere, which is what
guarantees the **same address on every chain**. On any source chain the relayer proves the route's
single leaf; if that chain's beacon has the route's endpoints/token configured the deposit proceeds,
otherwise the implementation reverts `RouteNotConfigured` and the route is simply inert there. (Contrast
later **upgraded** roots, which are _not_ in the address — see _Upgrade Mechanism_.)

So for a destination identity `(finalRecipient, outputToken, destinationChainId)`:

```
destination identity  ──►  one canonical initialRoot  ──►  one address on every chain
   (the identity is encoded into the leaves of the initialRoot tree, not stored as separate args)
```

The hard rule: **nothing mutable or chain-specific may enter address derivation** — not the live
`activeRoot` (it changes), not the implementation (it changes globally via the beacon), not a per-chain
root. The address commits only `initialRoot` and the caller-chosen `salt` (plus fixed deployment
substrate: the factory and the **beacon = `CounterfactualBeacon`**). This indirection is exactly what lets one address keep a stable
identity while its routes and logic are upgraded underneath it.

> A `BeaconProxy`'s init code embeds the **beacon address** (the `CounterfactualBeacon`) and the
> `initialize(initialRoot)` constructor `data` — **not** the implementation. So the implementation
> (the beacon's target) never affects the address and is the **only** piece free to differ per chain.
> The **factory** and the **`CounterfactualBeacon`** (as beacon) must be deployed deterministically at
> identical addresses on every chain (they're in the proxy's init code: `registry(beacon) → proxy
address`). They are permanent constants, never versioned. Compile the counterfactual stack under the
> dedicated `[profile.counterfactual]` so the creation bytecode is byte-identical.

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

## Chain Configuration (beacon-provided, immutable)

Every chain-specific value the leaf implementations need lives on the per-chain `CounterfactualBeacon` as
a **`public immutable`**, exposed by a named getter:

```
signer  spokePool  wrappedNativeToken
cctpSrcPeriphery  cctpTokenMessenger  cctpSourceDomain
oftSrcPeriphery  oftSrcEid
usdc  usdt        (one named getter per supported token)
```

A leaf implementation runs under delegatecall, so `address(this)` is the proxy; it resolves the beacon
from the proxy's standard **ERC-1967 beacon slot** (`ERC1967Utils.getBeacon()`) and reads what it needs —
holding **no immutables of its own**. Token resolution differs by bridge: **SpokePool is input-token-
agnostic** — its leaf carries the beacon getter selector (`inputTokenGetter`, e.g. `beacon.usdc.selector`
or `beacon.nativeToken.selector`), which it resolves with a guarded staticcall. Native vs ERC-20 is
decided by the **resolved value**, not the selector: the well-known sentinel
`0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE` ⇒ native deposit (the SpokePool input token is
`beacon.wrappedNativeToken()`); any other address ⇒ ERC-20. So one implementation serves every registered
token and one leaf can serve both flavors — on a chain whose `beacon.nativeToken()` returns the sentinel
it behaves as a native route; on a chain whose `beacon.nativeToken()` returns an ERC-20 (because that
chain has no native gas token to route through), the same leaf behaves as an ERC-20 route.
**CCTP / Vanilla CCTP** read `beacon.usdc()` directly (USDC-only bridges). **OFT** is also selector-driven:
its leaf carries a `peripheryGetter` naming which `SponsoredOFTSrcPeriphery` getter to use (today
`beacon.oftSrcPeriphery.selector`, the USDT0 periphery). Each OFT periphery is single-token (immutable
`TOKEN()`), so naming the periphery selects the input token, which the impl reads from the resolved
periphery — supporting many OFT tokens with one impl. A getter that returns `address(0)` on a given chain
means that route isn't live there — the implementation reverts `RouteNotConfigured`. Adding a token (a new
SpokePool token getter, or a new OFT periphery getter for a real OFT token) is a beacon upgrade, but
existing leaves can then name it with no impl change.

**Why immutable, and how it changes.** `implementation` and `upgradeRoot` remain mutable storage (they are
meant to change). The chain config does **not** use setters: each value is `immutable`, baked into the
registry implementation's bytecode (correctly readable through the proxy under delegatecall). Changing a
value — or adding a token — means deploying a new `CounterfactualBeacon` implementation and
**`upgradeToAndCall`-ing** the proxy to it. This is heavier than a setter but more auditable (config can't
be silently flipped) and keeps the proxy address constant.

**Deploy parity (bootstrap → upgrade).** The beacon **proxy** address must be identical on every chain (it
is embedded in every `BeaconProxy` and in the factory). But the chain-specific immutables make the registry
_implementation_ address differ per chain, so the proxy can't be created pointing straight at it. Instead:
deploy a chain-identical, no-arg `CounterfactualBeaconBootstrap` (same address everywhere), create the
`ERC1967Proxy` against it with **chain-invariant init calldata** (initialize to the deterministic deployer,
not the per-chain owner — then transfer ownership afterwards), then `upgradeToAndCall` to the chain-specific
`CounterfactualBeacon` implementation. Identical proxy init code ⇒ identical proxy address. (The dispatcher
and all leaf implementations are now constructor-arg-free or take only the chain-invariant beacon address,
so they too share one address per chain — see _Execution Fees_.)

> Note: absolute fee caps are **per-chain, per-token** beacon values, not leaf constants. A leaf names a
> cap via a `bytes4 maxExecutionFeeGetter` selector (e.g. `beacon.usdcCctpMaxExecutionFee.selector`,
> `beacon.usdcSpokePoolMaxExecutionFee.selector`); the impl resolves it with `_resolveBeaconUint`. So the
> same leaf carries the right cap on every chain. The vanilla CCTP leaf additionally names a **relative**
> cap via `cctpMaxFeeBpsGetter` (e.g. `beacon.usdcCctpMaxFeeBps.selector`), bounding the submitter-chosen
> Circle `maxFeeCctp` in bps of the burned amount. (`maxFeeBps`, being relative, stays in the SpokePool
> leaf.)

---

## The Counterfactual's Own Merkle Tree (`activeRoot`)

This is the deposit-authorization tree — same leaf encoding as the base system:

```
leaf = keccak256( bytes.concat( keccak256( abi.encode(implementation, keccak256(params)) ) ) )
```

Two kinds of leaves:

### Route leaves (one per route, chain-agnostic)

Each names a **bridge-specific implementation** and a route-specific `params`:

```
implementation = CounterfactualDepositSpokePool
               | CounterfactualDepositCCTP | CounterfactualDepositVanillaCCTP | CounterfactualDepositOFT
params         = destination identity + quote params + maxExecutionFeeGetter (+ maxFeeBps for SpokePool)
                 [+ inputTokenGetter for SpokePool] [+ peripheryGetter for OFT]
                 (no sourceChainId, no raw token address, no absolute fee cap)
```

The leaf is **chain-agnostic**: it carries no source chain id and no raw token address. How the input
token is named depends on the bridge:

- **SpokePool** is **input-token-agnostic**: the leaf carries an `inputTokenGetter` — the 4-byte selector
  of the beacon getter that resolves the per-chain token (e.g. `beacon.usdc.selector` or
  `beacon.nativeToken.selector`). The selector is chain-invariant; native vs ERC-20 is decided by the
  **resolved value** (`NATIVE_SENTINEL = 0xEeee…EEeE` ⇒ native, wrapped via
  `beacon.wrappedNativeToken()`; otherwise ⇒ ERC-20). One leaf can name `beacon.nativeToken.selector` and
  behave as native on chains that return the sentinel and as ERC-20 on chains whose `nativeToken()`
  returns a token address.
- **CCTP / Vanilla CCTP** bridge USDC, so their implementations read `beacon.usdc()` directly — no
  token field in the leaf.
- **OFT** carries a `peripheryGetter` — the selector of the beacon getter for the
  `SponsoredOFTSrcPeriphery` to use. Each periphery is single-token (immutable `TOKEN()`), so naming the
  periphery selects the input token (read from the resolved periphery); more OFT tokens = more periphery
  getters (a beacon upgrade), with no leaf/impl change.

In all cases the bridge endpoints, CCTP domain / OFT EID and fee `signer` are read from the beacon at
runtime, so `initialRoot` holds **one leaf per route**, not one per source chain.

Because a leaf is intentionally valid everywhere, there is **no `sourceChainId` / `block.chainid` check**:
per-chain behaviour comes entirely from the beacon's config. A route that a given chain's beacon does not
configure (zero endpoint or token) reverts `RouteNotConfigured` there — the leaf is inert, not
exploitable. SpokePool needs **no per-token implementation variants and no per-variant EIP-712 name**:
`inputTokenGetter` lives in `params`, so it is committed in `routeParamsHash` (which the SpokePool fee
signature binds), meaning a signature for one token never validates for another; cross-chain replay is
independently prevented by the `chainId` in the EIP-712 domain.

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
beacon, which is global and immediate.)

### Implementation — global, via the beacon (instant)

Implementation is shared logic, so it is administered **once, globally**: the admin calls
`setImplementation(impl)` on the registry (the beacon). Because every counterfactual is a `BeaconProxy`
that resolves `beacon.implementation()` **live on each call**, all proxies use the new implementation
**immediately** — there is **no per-proxy upgrade, no `syncImplementation`, and no bootstrap**. The
registry validates the target is a contract (`NotAContract`) **and that its immutable `BEACON()` points
back at this beacon** (`WrongBeacon`) — catching the catastrophic error of retargeting every proxy to logic
bound to a different beacon (which would silently brick `updateRoot`). (This guards the wrong-beacon
footgun, **not** ERC-7201 storage-layout drift, which every beacon target must independently preserve.)
The admin is otherwise trusted since setting it instantly retargets every proxy.

### Root — per-proxy, proof-gated

Each proxy's `activeRoot` is unique (it encodes that identity's routes), so root updates are
**per-proxy**, authorized by the upgrade tree:

```
leaf = keccak256( bytes.concat( keccak256( abi.encode(proxyAddress, latestRoot) ) ) )
```

The double hash is the same OpenZeppelin `StandardMerkleTree` encoding used by the Route Tree: hashing
the leaf preimage twice makes a leaf hash structurally distinct from an internal node (which is the hash
of two concatenated 32-byte child hashes), closing the second-preimage ambiguity where a crafted 64-byte
leaf preimage — and `abi.encode(address, bytes32)` is exactly 64 bytes — could otherwise be reinterpreted
as an internal node (or vice versa). Off-chain tree builders must use this exact encoding; a
single-hashed tree produces an `upgradeRoot` whose proofs never verify on-chain.

An executor calls `proxy.updateRoot(newRoot, proof)`; the proxy recomputes
`leaf = keccak256(bytes.concat(keccak256(abi.encode(address(this), newRoot))))`, verifies `proof` against
`CounterfactualBeacon.upgradeRoot()`, and on success sets `activeRoot = newRoot` — only the **exact** value
the leaf commits. There is no admin check on the proxy; the root update is gated **solely** by the
registry proof.

**Upgrade Tree construction (two rules).** The Upgrade Tree is maintained **per chain** — each chain's
`CounterfactualBeacon` carries its own `upgradeRoot`:

1. **Leaves are not restricted to counterfactuals recently touched on this chain.** A counterfactual has
   the **same address on every chain** and can be funded on any of them, so chain X's Upgrade Tree may
   include a `(proxy, latestRoot)` leaf for any counterfactual that should be upgradeable on X — not only
   ones created or funded there. Each chain's Upgrade Tree is maintained **independently**, so the proxy
   sets are **not required to match** across chains (and in practice will differ — by publish cadence and
   by which counterfactuals the operator chooses to include on each chain).
2. **A proxy's `latestRoot` is now chain-invariant.** Route Trees are chain-agnostic (their leaves carry
   no chain specifics — see _Route leaves_), so a given proxy's target root is the **same value on every
   chain**. A `(proxy, latestRoot)` leaf is therefore identical across chains; the only per-chain freedom
   is _which_ proxies each chain's Upgrade Tree includes. (This is simpler than the earlier model, where an
   upgraded Route Tree was per-chain and the backend had to avoid cross-chain leaves.)

A given proxy appears in a chain's Upgrade Tree **at most once** — the no-downgrade invariant is simply
**one leaf per proxy per Upgrade Tree**. There is no execute-time `sourceChainId == block.chainid`
check to fall back on (leaves are intentionally chain-agnostic); a chain that hasn't configured a route's
endpoints/token simply reverts `RouteNotConfigured` for it.

To **activate a newly-added route and use it in one transaction**, an executor can call
`proxy.updateRootAndExecute(newRoot, updateProof, implementation, params, submitterData, executeProof)`:
it runs `updateRoot` then `execute`, but **skips the update when the proxy is already at `newRoot`** (so it
never reverts `RootUnchanged` for an already-current proxy). This is the only case where a proxy's stale
`activeRoot` would otherwise block an `execute` (the route exists in the newer root but the proxy hasn't
been bumped) — there is no versioning, so `execute` is never blocked merely for being "old," only for
the proven route not being in the current `activeRoot`. Internally `execute` / `updateRoot` /
`updateRootAndExecute` share `_execute` / `_updateRoot` helpers, so the verification logic is not duplicated.

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
3. **Chain-specific values (bridge endpoint, CCTP domain / OFT EID, input token, fee `signer`)** — _not_
   in `params`; read from the per-chain `CounterfactualBeacon` at runtime (the token via the named getter
   the implementation is hardwired to). This is what makes the leaf chain-agnostic; an unset value reverts
   `RouteNotConfigured`. There is no `sourceChainId` and no `block.chainid` check (see _Chain Configuration_).
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

All four bridge implementations (`CounterfactualDepositSpokePool` / `CounterfactualDepositCCTP` /
`CounterfactualDepositVanillaCCTP` / `CounterfactualDepositOFT`) **must** support a **dynamic execution fee** chosen at execution time by
the submitter: the fee is paid in the input token to an `executionFeeRecipient`, and only
`amount − executionFee` is bridged. Because the fee is not committed in the route leaf, it must be
**authorized by an off-chain `signer` and verified on-chain**. We reproduce the scheme used on the
`taylor/counterfactual-route-policy` branch verbatim so off-chain quoting/tooling stays compatible.

Mechanism (identical across the four impls):

- Each impl is an **`EIP712`** contract (`name = "CounterfactualDeposit<Bridge>"` — the SpokePool
  variants use distinct names, `…SpokePoolUsdc` / `…SpokePoolNative`; `version = "v2.0.0"`). The
  **`signer`** is **not** an impl immutable — it is read from `beacon.signer()` at verification time, so
  rotating it is a beacon upgrade (no impl redeploy) and every impl on a chain shares one signer. Under
  delegatecall the EIP-712 domain's `verifyingContract` resolves to `address(this)` = the
  **counterfactual proxy**, so a signature is bound to one proxy and cannot be replayed against another.
- `submitterData` carries the runtime `executionFee`, a `signatureDeadline`, and a
  `counterfactualSignature` (the fee authorization). `_verifySignature` reverts `SignatureExpired` if
  `block.timestamp > signatureDeadline`, then requires
  `ECDSA.recover(_hashTypedDataV4(structHash), counterfactualSignature) == beacon.signer()` (else
  `InvalidSignature`).
- The fee's **upper bound** is **per-chain, per-token**: the leaf carries a `bytes4 maxExecutionFeeGetter`
  selector and the impl resolves the cap from the beacon (`_resolveBeaconUint`). For CCTP/Vanilla CCTP/OFT
  that resolved value is the `maxExecutionFee`; for SpokePool it is the fixed component of the combined
  `maxFee = cap + maxFeeBps × inputAmount` cap (which bounds the implicit relayer fee + execution fee
  together via `_checkFee`, with `maxFeeBps` still in the leaf). For
  SpokePool, a leaf-committed `checkStableExchangeRate` bool gates the rate-derived relayer-fee term: when
  `false` (e.g. non-stable pairs, where `stableExchangeRate` can't bound the relayer fee and `outputAmount`
  is instead trusted via the signature), the relayer-fee term is dropped and only `executionFee` is bounded
  by `maxFee`; when `true`, the existing relayer-fee + execution-fee bound applies.
- Native-token deposits (SpokePool) pay the fee via a `call{value: executionFee}`; ERC-20 deposits via
  `safeTransfer`.

Per-bridge typehash and binding:

| Impl             | EIP-712 typehash                                                                                                                                                                                                                             | Route / amount binding                                                                                                                                                                                                                    |
| ---------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **SpokePool**    | `ExecuteDeposit(address clone,bytes32 routeParamsHash,uint256 inputAmount,uint256 outputAmount,bytes32 exclusiveRelayer,uint32 exclusivityDeadline,uint32 quoteTimestamp,uint32 fillDeadline,uint32 signatureDeadline,uint256 executionFee)` | Binds **everything explicitly** — `clone`, `routeParamsHash`, and all runtime fields — because there is no separate periphery quote signature.                                                                                            |
| **CCTP**         | `ExecuteCCTP(bytes32 routeParamsHash,bytes32 nonce,uint256 executionFee,uint32 signatureDeadline)`                                                                                                                                           | Binds the **route** (`routeParamsHash`) and fee explicitly; clone bound via the domain; `amount` bound **transitively** through the periphery quote signature; `nonce` gives single-use replay protection once the periphery consumes it. |
| **Vanilla CCTP** | `ExecuteVanillaCCTP(bytes32 routeParamsHash,uint256 amount,uint256 executionFee,uint256 maxFeeCctp,uint32 minFinalityThreshold,uint32 signatureDeadline)`                                                                                    | No periphery, so binds **everything explicitly** — `routeParamsHash` (the leaf), `amount`, both fees and the finality threshold; clone bound via the EIP-712 domain. Replay protection is the short `signatureDeadline` (no nonce).       |
| **OFT**          | `ExecuteOFT(bytes32 routeParamsHash,bytes32 nonce,uint256 executionFee,uint32 signatureDeadline)`                                                                                                                                            | Same as CCTP (`routeParamsHash` includes the `peripheryGetter`, so the fee signature is bound to the chosen input-token periphery).                                                                                                       |

> CCTP and OFT additionally forward a **separate periphery quote signature** (`peripherySignature`) to
> the sponsored-bridge periphery unchanged — **two signatures per execute**. SpokePool calls
> `SpokePool.deposit` directly (no periphery), so it has only the one EIP-712 fee signature and
> therefore must bind the clone, route hash, and all runtime fields in its own typehash. **Vanilla CCTP**
> likewise calls `ITokenMessengerV2` directly (no periphery), so it too is single-signature and binds the
> route hash + amount in its own typehash (see _Vanilla CCTP route_).
>
> **Trust split (CCTP/OFT).** The counterfactual `counterfactualSignature` authorizes the **route**
> (`routeParamsHash`) and the `(nonce, executionFee, signatureDeadline)` — i.e. the route + **fee** — but
> not `amount`. The **amount, recipient, and destination action** are authorized by the separate
> `peripherySignature` over the Sponsored quote
> (committed in `SponsoredCCTPQuoteLib` / OFT `QuoteSignLib`). Neither signature alone authorizes a full
> transfer — a complete execution requires **both**, and `nonce` uniqueness at the periphery prevents fee
> replay.

> Note for the chain-agnostic model: the leaf implementations hold **no immutables** — neither the
> `signer` nor any endpoint/token. The `signer` is a single per-chain value on the beacon
> (`beacon.signer()`), so fee signatures verify consistently across chains by construction and rotating
> it is a beacon upgrade, not an impl redeploy. With nothing to configure, each leaf implementation
> compiles to **identical bytecode and deploys to one CREATE2 address on every chain** — which is exactly
> what lets a single leaf (which names the impl by address) be valid everywhere.

---

## Vanilla CCTP route (`CounterfactualDepositVanillaCCTP`)

`CounterfactualDepositCCTP` bridges through the **sponsored** path (`SponsoredCCTPSrcPeriphery` →
`SponsoredCCTPDstPeriphery`), whose destination periphery runs Across's HyperCore / relayer-sponsorship
machinery. `CounterfactualDepositVanillaCCTP` is the **non-sponsored** alternative: it calls Circle's
`ITokenMessengerV2` **directly**, so USDC mints natively on the destination with no Across destination
contract involved. It is an ordinary per-bridge leaf implementation (named by the leaf's `implementation`
field, delegatecalled by the dispatcher) — adding it needs no dispatcher or factory change; it reads the
CCTP TokenMessenger (`beacon.cctpTokenMessenger()`) and burn token (`beacon.usdc()`) from the beacon.

**Two destination shapes, one branch on `hookData`:**

- **Plain CCTP v2 (fast or standard)** — `hookData` empty ⇒ `depositForBurn`. USDC mints to `mintRecipient`
  on `destinationDomain`. Fast vs standard is a **runtime choice**: the submitter supplies
  `maxFeeCctp`/`minFinalityThreshold` at execution time (standard ⇒ `maxFeeCctp = 0`); `maxFeeCctp` is
  capped at the beacon's `<cctpMaxFeeBpsGetter>` bps of the burned amount.
- **HyperCore** ([Circle docs](https://developers.circle.com/cctp/concepts/cctp-on-hypercore)) — `hookData`
  non-empty ⇒ `depositForBurnWithHook`. A HyperCore transfer is just a CCTP burn to **HyperEVM (domain 19)** where `mintRecipient` is Circle's **`CctpForwarder`** proxy and `hookData` is its envelope; the
  forwarder mints on HyperEVM, then routes through `CoreDepositWallet` to the HyperCore account. The
  contract treats `mintRecipient` and `hookData` as **opaque** — the forwarder address and hook bytes are
  built off-chain into the route leaf, so the contract carries no HyperCore-specific logic.

  Circle's `CctpForwarderHookData` envelope (built off-chain; documented here for the leaf builder):

  ```
  bytes 0–23   bytes24  magic "cctp-forward"
  bytes 24–27  uint32   hook version (0)
  bytes 28–31  uint32   hook data length (24 = 20-byte recipient + 4-byte destinationId)
  bytes 32–51  address  forwardRecipient (the HyperCore recipient)
  bytes 52–55  uint32   destinationId (CoreDepositWallet routing id)
  ```

  (Arbitrum → HyperCore has no fast-transfer fee.)

**Authorization.** There is no periphery quote signature, so — unlike the sponsored CCTP/OFT impls — the
route and amount are **not** bound transitively. Instead the impl's own EIP-712 signature binds them
directly (mirroring SpokePool):
`ExecuteVanillaCCTP(bytes32 routeParamsHash,uint256 amount,uint256 executionFee,uint256 maxFeeCctp,uint32 minFinalityThreshold,uint32 signatureDeadline)`,
where `routeParamsHash = keccak256(params)` is the exact merkle-leaf params and `verifyingContract`
resolves to the proxy. `beacon.signer()` authorizes it — including the runtime `maxFeeCctp` and
`minFinalityThreshold`, so the submitter can't alter the fast/standard choice or Circle fee bound it
signed. The two fees are additionally capped **independently** against the per-chain getters the leaf
names: `executionFee ≤ beacon.<maxExecutionFeeGetter>()` (the same `usdcCctpMaxExecutionFee` the
sponsored CCTP leaf uses) and `maxFeeCctp ≤ beacon.<cctpMaxFeeBpsGetter>()` bps of the burned amount —
either failing check reverts.
**Replay protection is the short
`signatureDeadline`** — there is no nonce, so a
re-funded proxy could be re-executed within the signature window; keep deadlines short. ERC-20 (USDC) only.

---

## Trust Model

- The **depositor** trusts the route set baked into `initialRoot`, and trusts the `CounterfactualBeacon`
  admin to authorize only safe upgrades for their proxy.
- The **`CounterfactualBeacon` admin** is the system's only admin: it sets the global `implementation` (the
  beacon target) every proxy runs, and curates the `(proxy, latestRoot)` tree that authorizes per-proxy
  root updates. Use `Ownable2Step` + multisig. This role is **effectively all-powerful over funds**:
  setting the beacon `implementation` to a malicious/buggy contract **instantly** retargets every proxy
  (they resolve it live), and that impl runs with each proxy's balance. A **timelock** would give users
  a window to withdraw before a new implementation takes effect, but is **omitted in this implementation**
  — a known residual risk, mitigated only by trusting the multisig admin. (Revisit if a timelock
  is wanted later — note a beacon makes upgrades immediate, so a timelock matters _more_ here.)
  The admin **also owns the chain config** (bridge endpoints, CCTP domain / OFT EID, fee `signer`, token
  addresses). Because those are `public immutable`, the admin cannot change them with a setter — a change
  (or adding a token) is a **UUPS upgrade** of the registry implementation, which is more visible and
  auditable than a setter, but still admin-gated: an upgrade to a registry that mis-maps a token or
  endpoint could redirect a route's funds. Same trust class as `setImplementation`; mitigated by the
  multisig (and, if added later, a timelock).
- The **executor** is untrusted and permissionless: it can only apply a root the registry's tree already
  authorizes (exact leaf value) — it chooses neither the implementation (beacon-set) nor the root.
- The **per-bridge implementations** have full delegatecall power in the proxy's frame — the trusted
  code to audit. A proxy can only ever run the implementation the registry admin set as the beacon target.
- The **execution-fee `signer`** (a `public immutable` on the beacon, `beacon.signer()`, rotated via a
  registry upgrade) is trusted to authorize only fair runtime `executionFee` values (bounded by the leaf
  cap). It cannot redirect funds — the recipient is the pinned identity — only attest to the fee; an
  unsigned or expired fee reverts.
- The **relayer** is untrusted: it can only move the proxy's funds to the pinned `finalRecipient` via
  an authorized route.
