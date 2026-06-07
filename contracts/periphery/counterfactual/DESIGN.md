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
6. **Dynamic, signed execution fees** — all three bridge implementations accept an `executionFee`
   chosen at execution time via `submitterData`, authorized by an off-chain `signer` and verified
   on-chain

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
> A Route Tree root is therefore a _leaf value_ inside the Upgrade Tree.

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
`initialRoot` **and `salt`** must be **identical on every chain** (`salt = 0` satisfies this trivially). The routes a deposit uses, however, are
source-chain-specific (Arbitrum deposits use Arbitrum's SpokePool, Base deposits use Base's, etc.). We
reconcile this by **requiring `initialRoot` to commit a tree that contains the routes for all source
chains** to the one destination identity. This all-chains rule is what guarantees the **same address on
every chain**: `initialRoot` is in the address, so it must be byte-identical everywhere, so it must
already enumerate every chain's route up front. On any given source chain, the relayer proves the leaf
matching that chain's route; the root is the same everywhere. (Contrast later **upgraded** roots, which
are _not_ in the address and are therefore per-chain — see _Upgrade Mechanism_.)

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
implementation = CounterfactualDepositSpokePool | CounterfactualDepositCCTP | CounterfactualDepositVanillaCCTP | CounterfactualDepositOFT
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
registry validates the target is a contract (`NotAContract`) **and that its immutable `BEACON()` points
back at this beacon** (`WrongBeacon`) — catching the catastrophic error of retargeting every proxy to logic
bound to a different beacon (which would silently brick `updateRoot`). (This guards the wrong-beacon
footgun, **not** ERC-7201 storage-layout drift — see Open Question #5.) The admin is otherwise trusted (and
timelocked-by-intent, D19) since setting it instantly retargets every proxy.

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

**Upgrade Tree construction (two rules).** The Upgrade Tree is maintained **per chain** — each chain's
`CounterfactualBeacon` carries its own `upgradeRoot`:

1. **Leaves are not restricted to counterfactuals recently touched on this chain.** A counterfactual has
   the **same address on every chain** and can be funded on any of them, so chain X's Upgrade Tree may
   include a `(proxy, latestRoot)` leaf for any counterfactual that should be upgradeable on X — not only
   ones created or funded there. Each chain's Upgrade Tree is maintained **independently**, so the proxy
   sets are **not required to match** across chains (and in practice will differ — by publish cadence and
   by which counterfactuals the operator chooses to include on each chain).
2. **Every leaf's `latestRoot` is a Route Tree for THIS chain only.** What differs per chain is the
   _target_ root: a leaf in chain X's tree points to that proxy's **chain-X** Route Tree. The backend
   **must not** place a leaf whose Route Tree targets a different source chain into chain X's Upgrade Tree.
   Unlike `initialRoot` — which is baked into the address and must therefore enumerate routes for _all_
   source chains (see _Address Determinism_) — an upgraded Route Tree is **not** part of the address, so it
   is per-chain and lean.

Because each chain's Upgrade Tree only ever targets that chain's Route Trees, a given proxy appears in it
**at most once** — the no-downgrade invariant is simply **one leaf per proxy per (per-chain) Upgrade
Tree** (D25). The execute-time `sourceChainId == block.chainid` check is retained purely as
defense-in-depth (a stray foreign-chain leaf would be inert), but correctness does **not** rely on it:
trees are built single-chain by construction.

To **activate a newly-added route and use it in one transaction**, an executor can call
`proxy.updateRootAndExecute(newRoot, updateProof, implementation, params, submitterData, executeProof)`:
it runs `updateRoot` then `execute`, but **skips the update when the proxy is already at `newRoot`** (so it
never reverts `RootUnchanged` for an already-current proxy). This is the only case where a proxy's stale
`activeRoot` would otherwise block an `execute` (the route exists in the newer root but the proxy hasn't
been bumped) — versioning was removed (D28), so `execute` is never blocked merely for being "old," only for
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

All four bridge implementations (`CounterfactualDepositSpokePool` / `CounterfactualDepositCCTP` /
`CounterfactualDepositVanillaCCTP` / `CounterfactualDepositOFT`) **must** support a **dynamic execution fee** chosen at execution time by
the submitter: the fee is paid in the input token to an `executionFeeRecipient`, and only
`amount − executionFee` is bridged. Because the fee is not committed in the route leaf, it must be
**authorized by an off-chain `signer` and verified on-chain**. We reproduce the scheme used on the
`taylor/counterfactual-route-policy` branch verbatim so off-chain quoting/tooling stays compatible.

Mechanism (identical across the four impls):

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
  `maxExecutionFee` for CCTP/Vanilla CCTP/OFT, or the combined `maxFeeFixed + maxFeeBps × inputAmount` cap for
  SpokePool (which bounds the implicit relayer fee + execution fee together via `_checkFee`). For
  SpokePool, a leaf-committed `checkStableExchangeRate` bool gates the rate-derived relayer-fee term: when
  `false` (e.g. non-stable pairs, where `stableExchangeRate` can't bound the relayer fee and `outputAmount`
  is instead trusted via the signature), the relayer-fee term is dropped and only `executionFee` is bounded
  by `maxFee`; when `true`, the existing relayer-fee + execution-fee bound applies.
- Native-token deposits (SpokePool) pay the fee via a `call{value: executionFee}`; ERC-20 deposits via
  `safeTransfer`.

Per-bridge typehash and binding:

| Impl             | EIP-712 typehash                                                                                                                                                                                                                             | Route / amount binding                                                                                                                                                                                             |
| ---------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **SpokePool**    | `ExecuteDeposit(address clone,bytes32 routeParamsHash,uint256 inputAmount,uint256 outputAmount,bytes32 exclusiveRelayer,uint32 exclusivityDeadline,uint32 quoteTimestamp,uint32 fillDeadline,uint32 signatureDeadline,uint256 executionFee)` | Binds **everything explicitly** — `clone`, `routeParamsHash`, and all runtime fields — because there is no separate periphery quote signature.                                                                     |
| **CCTP**         | `ExecuteCCTP(bytes32 nonce,uint256 executionFee,uint32 signatureDeadline)`                                                                                                                                                                   | Clone bound via the domain; amount/route bound **transitively** through the periphery quote signature (which commits `(route, nonce)`); `nonce` gives single-use replay protection once the periphery consumes it. |
| **Vanilla CCTP** | `ExecuteVanillaCCTP(bytes32 routeParamsHash,uint256 amount,uint256 executionFee,uint32 signatureDeadline)`                                                                                                                                   | No periphery, so binds **everything explicitly** — `routeParamsHash` (the leaf), `amount`, and the fee; clone bound via the EIP-712 domain. Replay protection is the short `signatureDeadline` (no nonce).         |
| **OFT**          | `ExecuteOFT(bytes32 nonce,uint256 executionFee,uint32 signatureDeadline)`                                                                                                                                                                    | Same as CCTP.                                                                                                                                                                                                      |

> CCTP and OFT additionally forward a **separate periphery quote signature** (`peripherySignature`) to
> the sponsored-bridge periphery unchanged — **two signatures per execute**. SpokePool calls
> `SpokePool.deposit` directly (no periphery), so it has only the one EIP-712 fee signature and
> therefore must bind the clone, route hash, and all runtime fields in its own typehash. **Vanilla CCTP**
> likewise calls `ITokenMessengerV2` directly (no periphery), so it too is single-signature and binds the
> route hash + amount in its own typehash (see _Vanilla CCTP route_).
>
> **Trust split (CCTP/OFT).** The counterfactual `counterfactualSignature` authorizes **only** the
> `(nonce, executionFee, signatureDeadline)` — i.e. the **fee**. The **route, amount, recipient, and
> destination action** are authorized by the separate `peripherySignature` over the Sponsored quote
> (committed in `SponsoredCCTPQuoteLib` / OFT `QuoteSignLib`). Neither signature alone authorizes a full
> transfer — a complete execution requires **both**, and `nonce` uniqueness at the periphery prevents fee
> replay (see Open Question #2).

> Note for the upgradeable model: the impl is the **beacon target** (swapped globally via
> `setImplementation`, never via the proxy and never in the address), and its constructor-immutable
> `signer` lives in the implementation bytecode. The impl need **not** be deterministic for _address_
> parity (it is in no address — see _Address Determinism_), but the **same `signer` must be used on every
> chain** for fee signatures to verify consistently; deploying the impl deterministically (Phase 0/5) is
> the simplest way to guarantee that.

---

## Vanilla CCTP route (`CounterfactualDepositVanillaCCTP`)

`CounterfactualDepositCCTP` bridges through the **sponsored** path (`SponsoredCCTPSrcPeriphery` →
`SponsoredCCTPDstPeriphery`), whose destination periphery runs Across's HyperCore / relayer-sponsorship
machinery. `CounterfactualDepositVanillaCCTP` is the **non-sponsored** alternative: it calls Circle's
`ITokenMessengerV2` **directly**, so USDC mints natively on the destination with no Across destination
contract involved. It is an ordinary per-bridge leaf implementation (named by the leaf's `implementation`
field, delegatecalled by the dispatcher) — adding it needs no dispatcher / factory / beacon change.

**Two destination shapes, one branch on `hookData`:**

- **Plain CCTP v2 (fast or standard)** — `hookData` empty ⇒ `depositForBurn`. USDC mints to `mintRecipient`
  on `destinationDomain`. Fast vs standard is `minFinalityThreshold` (+ a `maxFee` derived from
  `cctpMaxFeeBps`); a standard transfer sets `cctpMaxFeeBps = 0`.
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
`ExecuteVanillaCCTP(bytes32 routeParamsHash,uint256 amount,uint256 executionFee,uint32 signatureDeadline)`,
where `routeParamsHash = keccak256(params)` is the exact merkle-leaf params and `verifyingContract`
resolves to the proxy. `signer` authorizes it, `executionFee ≤ maxExecutionFee` (the leaf cap) is checked
afterward, and **replay protection is the short `signatureDeadline`** — there is no nonce, so a re-funded
proxy could be re-executed within the signature window; keep deadlines short. ERC-20 (USDC) only.

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
