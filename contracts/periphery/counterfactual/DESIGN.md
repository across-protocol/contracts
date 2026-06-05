# Upgradeable Counterfactuals — Design

Status: design doc, not implementation. Author: Taylor (with Claude). Updated: 2026-06-04.

> **Implementation target: this repo (`across-protocol/contracts`), branch
> `taylor/counterfactual-upgradeable`.** This design supersedes earlier route-policy sketches: there
> is **no `RoutePolicy` contract**. Each counterfactual is its own **UUPS upgradeable proxy** that
> holds its route root in storage, and a single global **`UpgradeRegistry`** per chain governs how
> those proxies may be upgraded.

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
   tree (deposits, withdraws) and the global `UpgradeRegistry` (a per-proxy root tree + a global
   current implementation).
5. **Trustless injection** of the per-user fields (recipient, output token, destination chain) into
   bridge calldata.
6. **Dynamic, signed execution fees** — all three bridge implementations accept an `executionFee`
   chosen at execution time via `submitterData`, authorized by an off-chain `signer` and verified
   on-chain (matching the `taylor/counterfactual-route-policy` branch — see _Execution Fees_).

---

## Core Idea

Each counterfactual is a **UUPS upgradeable proxy** (ERC-1967) rather than an EIP-1167 minimal clone.
It stores a single mutable variable, `activeRoot`, which is the merkle root authorizing its deposit
routes. The proxy is deployed deterministically against a fixed, permanent **bootstrap
implementation** (so the real/upgradeable implementation never enters its address — see _Bootstrap
Deployment_), and `activeRoot` is initialized from an `initialRoot` passed in init code.

Two things are mutable post-deploy, and **neither enters address derivation**:

- **`activeRoot`** — the live route set (changed by a per-proxy root update).
- **the implementation** — the dispatch/bridge logic (synced to the registry's global
  `currentImplementation()` by a UUPS upgrade).

There is **no owner or admin** on the proxy. Authorization comes from the global `UpgradeRegistry`,
split along "shared vs. per-proxy":

- **Deposits** (and withdraws) dispatch by merkle proof against the counterfactual's own
  **`activeRoot`** — exactly as in the base system.
- **Implementation** (shared logic) is synced **permissionlessly** to the registry's admin-set global
  `currentImplementation()` — no proof, since a proxy can only ever land on the current canonical impl.
- **Root updates** (per-proxy routes) are applied by an executor with a proof against the registry's
  **upgrade tree** of `(proxy, latestRoot)` leaves.

```
═══════════════════════════ DEPOSIT (per counterfactual) ═══════════════════════════

relayer
  │ proxy.execute(implementation, params, submitterData, proof)
  ▼
┌─────────────────────────────┐  proof vs activeRoot (storage)
│ Counterfactual proxy (UUPS) │  verify leaf inclusion
│  activeRoot  : storage      │  DELEGATECALL implementation
│  implementation : ERC1967   │
└──────────────┬──────────────┘
               │ delegatecall: address(this) == proxy (holds funds)
               ▼
┌─────────────────────────────────┐  recipient ← finalRecipient (from identity)
│ CounterfactualDeposit{CCTP/OFT/  │  approve(bridge) ; bridge deposit with
│  SpokePool}  (per-bridge impl)   │  native recipient = finalRecipient
└──────────────┬──────────────────┘
               ▼
   SpokePool.deposit / CCTP depositForBurn / OFT send  →  delivered natively on dest


═══════════════════════════ UPGRADE (global registry, per chain) ═══════════════════════════

registry admin                            executor (permissionless)
 │ setCurrentImplementation(impl)          │ (a) proxy.syncImplementation()       impl ← currentImplementation()   [no proof]
 │ setRoot(treeOf (proxy,root))            │ (b) proxy.updateRoot(newRoot, proof) activeRoot ← newRoot             [proof vs tree]
 ▼                                         ▼
┌──────────────────────────────┐  read /   ┌─────────────────────────────┐
│ UpgradeRegistry              │  verify    │ Counterfactual proxy (UUPS) │
│  currentImplementation : addr│ ◄───────── │  (a) pull current impl       │
│  root : tree of (proxy,root) │            │  (b) leaf = keccak(this,     │
│  (admin-curated)             │            │      newRoot); verify proof  │
└──────────────────────────────┘            └─────────────────────────────┘
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
`activeRoot` (it changes), not the live implementation (it changes), not a per-chain root. The address
commits only `initialRoot` (plus fixed deployment substrate: the factory, the salt, and the **bootstrap
implementation**). This indirection is exactly what lets one address keep a stable identity while its
routes and logic are upgraded underneath it.

> The proxy's init code references a **bootstrap implementation, not the real one** (see _Bootstrap
> Deployment_), so the upgradeable implementation never affects the address — it is the **only** piece
> free to differ per chain. The **factory**, the **bootstrap**, and the **`UpgradeRegistry`** must all
> be deployed deterministically at identical addresses on every chain: they are in (or transitively
> baked into) the proxy's init code — the bootstrap embeds the registry as an immutable and the
> bootstrap address is in the preimage, so `registry → bootstrap → proxy address`. They are permanent
> constants, never versioned. Compile the counterfactual stack under the dedicated
> `[profile.counterfactual]` (Phase 0) so the creation bytecode is byte-identical.

---

## Bootstrap Deployment (keeping the implementation out of the address)

With a plain ERC-1967/UUPS proxy the implementation address sits in the init code, so it would enter
the CREATE2 preimage. We don't want the _real_ (upgradeable, versioned) implementation to affect the
address — only `initialRoot` should. So the proxy is deployed against a **fixed bootstrap
implementation** and immediately finalized to the real one:

- **`CounterfactualBootstrap`** — a tiny, permanent UUPS implementation deployed once per chain at a
  deterministic, constant address (same everywhere, like the factory). It does only:
  `initialize(bytes32 initialRoot)` (writes `activeRoot = initialRoot`), the permissionless
  `syncImplementation()`, and an `_authorizeUpgrade` that requires the target equal
  `UpgradeRegistry.currentImplementation()`. It has **no deposit logic**, so a proxy is unusable until
  finalized — a useful invariant. It is never changed, so it stays a stable address anchor.
- **The proxy commits to the bootstrap, not the real impl:**

  ```solidity
  new ERC1967Proxy{salt: 0}(BOOTSTRAP, abi.encodeCall(IBootstrap.initialize, (initialRoot)))
  ```

  Preimage = `f(factory, 0, ERC1967Proxy.creationCode, BOOTSTRAP, initialRoot)` — all constants except
  `initialRoot`, so `address = f(initialRoot)`. The real/final implementation is never in it.

- **The factory finalizes atomically.** Immediately after CREATE2 (same tx), the bootstrap's
  permissionless `syncImplementation()` does `upgradeToAndCall(UpgradeRegistry.currentImplementation(),
…)` — no proof needed, because the implementation address comes straight from the trusted registry's
  admin-set global default. `deployIfNeededAndExecute` bootstraps → finalizes → executes the deposit
  in one tx (also covering pre-funded counterfactual addresses).
- **Finalize is just the first sync.** `syncImplementation()` is idempotent and permissionless: the
  first call moves the proxy off the bootstrap; later calls move it to whatever
  `currentImplementation()` currently is. Implementation upgrades are therefore **global** (see
  _Upgrade Mechanism_), not in the per-proxy tree.

So the address is anchored to the permanent `BOOTSTRAP` + `initialRoot`; the live implementation
(seeded at finalize, changed by later upgrades) is storage-only and never re-enters address
derivation. Bootstrap and all real impls must share the `activeRoot` storage slot — use an ERC-7201
namespaced storage struct so the bootstrap's write is read correctly by every future implementation.

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

## Upgrade Mechanism (`UpgradeRegistry` + executor)

Upgrades are governed by the global registry, not by a per-proxy admin. The two mutable knobs are
administered differently, along the "shared vs. per-proxy" split:

- **`UpgradeRegistry`** — one global contract per chain, with an **admin** (the only admin in the
  system) maintaining:
  - `currentImplementation` — the canonical implementation **all** proxies run (shared logic).
  - `root` — the root of an **upgrade merkle tree** of `(proxy, latestRoot)` leaves, authorizing
    per-proxy **root** updates.
  - `version` — a counter bumped on every `setUpgradeRoot`, and `minRequiredVersion (<= version)` —
    together these let the admin **force** proxies onto a recent root (see _Enforcement_ below).

### Enforcement — `execute` requires the proxy to be up to date (D13)

The deposit/withdraw path is gated by `_requireUpToDate()`: `execute` reverts unless the proxy runs the
registry's `currentImplementation` (`StaleImplementation`) **and** its stored `rootVersion >=
registry.minRequiredVersion()` (`StaleRoot`). So a stale proxy must first remediate — `syncImplementation()`
for impl, `updateRoot()` for root (both permissionless and **un**gated) — before it can execute. This is
what makes a security-critical impl fix or route retirement actually bite: a stale proxy can't keep
depositing on old logic or a retired root. A proxy stamps its `rootVersion = registry.version()` on every
`updateRoot` and at deploy (a fresh proxy is born current — D26). Cost: ~one registry read per `execute`,
plus a sync/update before each proxy's next deposit after a bump.

### Implementation — global, permissionless sync

Implementation is shared logic, so it is administered **once, globally**. The admin sets
`currentImplementation`; thereafter **anyone** can push **any** proxy to it:

```solidity
function syncImplementation() external {
  // permissionless, no proof
  _upgradeToAndCallUUPS(UpgradeRegistry.currentImplementation(), "", false);
}
```

No proof is needed because a proxy can only ever land on the admin-curated **current** value, and
there is no old value to replay — a single slot makes the implementation version monotonic by
construction. `syncImplementation()` is also the bootstrap's `finalize()` (the first sync); see
_Bootstrap Deployment_. `_authorizeUpgrade` enforces the target equals `currentImplementation()`.

### Root — per-proxy, proof-gated

Each proxy's `activeRoot` is unique (it encodes that identity's routes), so root updates are
**per-proxy**, authorized by the upgrade tree:

```
leaf = keccak256( abi.encode( proxyAddress, latestRoot ) )
```

An executor calls `proxy.updateRoot(newRoot, proof)`; the proxy recomputes
`leaf = keccak256(abi.encode(address(this), newRoot))`, verifies `proof` against
`UpgradeRegistry.root()`, and on success sets `activeRoot = newRoot` — only the **exact** value the
leaf commits. There is no admin check on the proxy; the root update is gated **solely** by the registry
proof.

> **How the proxy knows the registry.** The `UpgradeRegistry` address is an **immutable in the
> implementation bytecode** (the bootstrap and every real impl) — _not_ a proxy state variable. It is a
> global per-chain constant (deployed deterministically at the same address on every chain), so
> per-proxy storage would only waste an `SSTORE`/`SLOAD`, bloat init code, and needlessly enter the
> CREATE2 preimage; an immutable lives in code, costs nothing at runtime, and never touches the proxy's
> address (the preimage references the constant _bootstrap_ address, not the registry). For the
> bootstrap, a hardcoded `constant` is also viable since the registry address is deterministic. If the
> registry ever must be replaced, migration goes through the normal upgrade path — the old registry sets
> `currentImplementation` to a new impl pointing at the new registry, adopted on the next
> `syncImplementation()`.

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

- The **depositor** trusts the route set baked into `initialRoot`, and trusts the `UpgradeRegistry`
  admin to authorize only safe upgrades for their proxy.
- The **`UpgradeRegistry` admin** is the system's only admin: it sets the global
  `currentImplementation` every proxy may run, and curates the `(proxy, latestRoot)` tree that
  authorizes per-proxy root updates. Use `Ownable2Step` + multisig. This role is **effectively
  all-powerful over funds**: because `syncImplementation()` is permissionless, a malicious or buggy
  `currentImplementation` can be applied to any proxy and run with its balance. A **timelock** would
  give users a window to withdraw before a new implementation takes effect, but is **omitted in this
  implementation (D19)** — so this is a known residual risk, mitigated only by trusting the multisig
  admin. (Revisit if a timelock is wanted later.)
- The **executor** is untrusted and permissionless: it can only sync a proxy to the registry's current
  implementation, or apply a root the registry's tree already authorizes (exact leaf value) — it
  chooses neither the impl nor the root.
- The **per-bridge implementations** have full delegatecall power in the proxy's frame — the trusted
  code to audit. A proxy can only ever run the implementation the registry admin set as
  `currentImplementation`.
- The **execution-fee `signer`** is trusted to authorize only fair runtime `executionFee` values
  (bounded by the leaf cap). It cannot redirect funds — the recipient is the pinned identity — only
  attest to the fee; an unsigned or expired fee reverts.
- The **relayer** is untrusted: it can only move the proxy's funds to the pinned `finalRecipient` via
  an authorized route.

---

## Differences From the Base Counterfactual

| Aspect                       | Base (immutable)                                  | Upgradeable (this design)                                                                     |
| ---------------------------- | ------------------------------------------------- | --------------------------------------------------------------------------------------------- |
| Proxy type                   | EIP-1167 minimal clone                            | ERC-1967 **UUPS upgradeable** proxy (deployed via a fixed bootstrap impl)                     |
| Route root                   | Immutable clone arg                               | Mutable **`activeRoot`** storage (init from `initialRoot`)                                    |
| Implementation               | Fixed dispatcher                                  | **Upgradeable** per proxy (UUPS); not in the address (bootstrap anchor)                       |
| Who can change impl          | No one                                            | Anyone, via permissionless `syncImplementation()` → registry's global `currentImplementation` |
| Who can change routes (root) | No one                                            | Permissionless **executor** with a proof vs the registry's `(proxy, latestRoot)` tree         |
| Admin                        | None                                              | None on the proxy; the **`UpgradeRegistry`** has the only admin                               |
| Cross-chain address          | Differs (root is chain-specific)                  | **Same** (`initialRoot` identical; all-source-chains tree)                                    |
| Deposit dispatch             | Merkle proof vs root                              | **Same**, but proof is vs `activeRoot` in storage                                             |
| Per-bridge impls             | `CounterfactualDeposit{CCTP,OFT,SpokePool}`       | **Same**, reused as leaf implementations                                                      |
| Withdraw / rescue            | `AdminWithdrawManager` + `WithdrawImplementation` | **Same**, as the withdraw leaf                                                                |

---

## Implementation Plan

### Phase 0 — Counterfactual build profile ✅ (profile in place)

`[profile.counterfactual]` already exists in `foundry.toml`: `src = contracts/periphery/counterfactual`,
`script = script/counterfactual`, isolated `out-counterfactual` / `cache-foundry-counterfactual`, and
**`bytecode_hash = "none"`** (strips the metadata hash so creation bytecode — and thus CREATE2
addresses — stays stable across commits and chains). Build/deploy with `FOUNDRY_PROFILE=counterfactual`.

The determinism-critical set that needs byte-identical bytecode is the **factory**, the **bootstrap**,
and the **`UpgradeRegistry`** (they fix proxy addresses via `registry → bootstrap → proxy`); the **real
implementation does not** (it is in no address). The profile _config_ is done, but the contracts it
will build are new (Phases 1–2). Remaining Phase-0 work: pin a fixed solc/optimizer combination for
those three contracts and add a `forge inspect <c> bytecode` cross-chain parity check once they exist.

### Phase 1 — Upgradeable counterfactual proxy + bootstrap ✅ DONE (contracts compile)

These **replace** the old immutable counterfactual contracts, reusing their names (D21). All live in
`contracts/periphery/counterfactual/`:

- **`CounterfactualBase`** (abstract) — the UUPS base storing `activeRoot` in an ERC-7201 namespaced
  slot; the immutable `UPGRADE_REGISTRY`; permissionless `syncImplementation()` and
  `updateRoot(newRoot, proof)`; `_authorizeUpgrade` gated to `currentImplementation`.
- **`CounterfactualDeposit`** — the real implementation (the registry's `currentImplementation`): the
  merkle dispatcher `execute(implementation, params, submitterData, proof)` verifying proofs against
  `activeRoot`, then delegatecalling `ICounterfactualImplementation.execute(params, submitterData)` (the
  impl decodes identity from `params`; **no** identity args). Implements `ICounterfactualDeposit`.
- **`CounterfactualBootstrap`** — the permanent, minimal bootstrap implementation, embedding the
  `UpgradeRegistry` as an immutable: `initialize(initialRoot)` + the inherited permissionless
  `syncImplementation()` (its first call is the `finalize()`). No deposit logic. Deployed
  deterministically (constant address per chain).
- **`CounterfactualDepositFactory`** — deterministic CREATE2 deployment of
  `ERC1967Proxy(BOOTSTRAP, initialize(initialRoot))` at salt 0, finalizing atomically; `predictAddress`
  / `deploy` / `deployAndExecute` / `deployIfNeededAndExecute`. `predictAddress` / `_initCode` are
  `virtual` for a Tron override (Q12).

> The old immutable-system tooling (its tests, deploy scripts, and the Clones-based
> `CounterfactualDepositFactoryTron`) is **superseded and currently left broken** — rebuilt in Phase 4
> (tests) / Phase 5 (deploy) / Q12 (Tron).

### Phase 2 — UpgradeRegistry + upgrade path

- **`UpgradeRegistry`** — global per-chain contract with an admin-settable `currentImplementation`
  (the impl all proxies sync to) and `root` (the `(proxy, latestRoot)` tree); `Ownable2Step` + multisig
  (timelock omitted in this implementation — see D19 / Trust Model). **Itself a UUPS proxy** (upgradeable;
  Q11 resolved). Deployed deterministically (same address per chain — required, since the bootstrap
  embeds it).
- **`syncImplementation()`** on the proxy — permissionless; upgrades to
  `UpgradeRegistry.currentImplementation()`; `_authorizeUpgrade` requires the target equal that value.
- **`updateRoot(newRoot, proof)`** on the proxy — recompute `leaf = keccak(this, newRoot)`, verify
  against `UpgradeRegistry.root()`, set `activeRoot`. No admin check.

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

- **Proxy / bootstrap / factory** — `initialRoot → activeRoot` init; deploy → finalize → deposit
  dispatch; deposits revert before finalize; cross-chain address determinism (same `initialRoot` ⇒ same
  address, independent of the real implementation).
- **UpgradeRegistry / upgrades** — sync to a bumped `currentImplementation`; `updateRoot` via proof;
  rejection of an unproven/forged root leaf; rejection once the registry root rotates (stale leaf
  invalid); `_authorizeUpgrade` rejects any target other than `currentImplementation`.
- **Per-bridge verticals (SpokePool, CCTP, OFT)** — happy-path deposit per bridge; `block.chainid !=
sourceChainId` rejection; valid / expired / forged fee signatures; over-cap fee rejection; native-ETH
  path where supported; the withdraw leaf (authorized vs. unauthorized).

### Phase 5 — Deployment

Deterministically deploy the factory, the **bootstrap implementation**, and the `UpgradeRegistry` at
identical addresses across chains (under `FOUNDRY_PROFILE=counterfactual`); deploy the real
implementation(s) per chain and set the registry's `currentImplementation`. Publish the route trees and
the initial upgrade tree. Verify same-address parity across chains (and that it is independent of the
real implementation). Record addresses in the generated address artifacts.

---

## Open Questions

1. **Factory / bootstrap / registry determinism.** Cross-chain address parity requires the
   **factory**, the **bootstrap**, and the **`UpgradeRegistry`** to be at identical addresses on every
   chain (`registry → bootstrap → proxy`). Lock this with deterministic deployment + the byte-identical
   profile (Phase 0). The real implementation no longer needs to be deterministic for address parity
   (it's not in any address), though it's still deployed deterministically for operational simplicity.
2. **Pre-deployment / finalize ordering.** An address can receive funds before its proxy is deployed.
   `deployIfNeededAndExecute` bootstraps → finalizes (to `currentImplementation()`) → executes the
   deposit atomically, so a proxy is never used in its bootstrap (deposit-less) state. A freshly
   finalized proxy starts at `initialRoot`; a registry-authorized route/impl upgrade only applies after
   a later executor `upgrade` tx. Confirm this ordering is acceptable.
3. ~~**Root replay / monotonicity.**~~ **RESOLVED (D25): no contract change.** Implementation is
   monotonic by construction (single `currentImplementation` slot). For **roots**, downgrade is
   prevented off-chain: registry-root **rotation** invalidates old trees' proofs, and the tree
   generator must enforce **at most one `(proxy, root)` leaf per proxy** per tree. Residual risk
   accepted: a tooling slip (duplicate/stale leaf) would be attacker-exploitable via the permissionless
   `updateRoot` — so the one-leaf-per-proxy invariant is a hard, tested requirement of the tree builder.
4. **`UpgradeRegistry` admin controls.** `Ownable2Step` + multisig from the start (timelock omitted in
   this implementation — D19); it is the only privileged role — it sets the global
   `currentImplementation` (which any proxy can then sync to) and curates the per-proxy root tree.
5. **UUPS upgrade safety.** Maintain storage-layout compatibility across implementations (`activeRoot`
   slot, ERC-1967 slots); add upgrade-safety checks/tests.
6. ~~**`AdminWithdrawManager` replay.**~~ **RESOLVED (D24): accepted as-is.** `signedWithdraw` is
   replayable within its deadline (no nonce/used-marking) — a conscious decision, since the payout is
   forced to the committed user, so replays only re-pay the rightful user.
7. **Admin actions via the counterfactual's own tree.** Beyond deposits/withdraws, decide whether any
   other privileged actions should be expressible as leaves in a proxy's `activeRoot` tree (vs. routed
   exclusively through the `UpgradeRegistry`).
8. ~~**Withdraws — what authorization, and is an admin needed?**~~ **RESOLVED (D12).** Withdraw is
   authorization-gated, not permissionless: `WithdrawImplementation` requires `msg.sender` to equal the
   `{admin, user}` committed in the leaf params (authenticated by the proof) — reused from v4 unchanged.
   `user` = self-rescue (picks any `to`); `admin` = `AdminWithdrawManager` (assisted rescue, forces
   payout to `user` on the signed path). The specific `user`/`admin` addresses are an **off-chain
   tree-config choice** (and, being leaf values, are part of the address) — not an open contract
   question. (Permissionless withdraw was rejected as a DoS vector; `signedWithdraw` replay accepted —
   D24.)
9. ~~**Should being up-to-date be required to execute?**~~ **RESOLVED (D13): yes.** `execute` now gates
   on `_requireUpToDate()`: the proxy must run the registry's `currentImplementation` (else
   `StaleImplementation`) and have `rootVersion >= registry.minRequiredVersion()` (else `StaleRoot`).
   Remediation is permissionless: `syncImplementation()` for impl, `updateRoot()` for root (neither is
   gated). Reverses the earlier "optional" stance.
10. ~~**Version counters on `UpgradeRegistry` and the proxy.**~~ **RESOLVED (D13): adopted (root only).**
    The registry has a `version` (bumped on every `setUpgradeRoot`) and an admin-set
    `minRequiredVersion (<= version)`; each proxy stores a `rootVersion` (stamped on `updateRoot`, and at
    deploy — D26). No separate _implementation_ version is needed — impl freshness is an exact address
    match against `currentImplementation`.
11. ~~**Is the `UpgradeRegistry` itself upgradeable?**~~ **RESOLVED (D19): yes — UUPS proxy, no
    timelock in this implementation.** It must have a permanent address anyway (the bootstrap embeds it,
    anchoring every proxy via `registry → bootstrap → proxy`), so a UUPS proxy keeps the address fixed
    while its logic can evolve (e.g. to add the version counters of #9/#10) — avoiding the awkward
    alternative where a non-upgradeable registry is "replaced" only by leaving the old one alive as a
    permanent redirector. Upgradeability doesn't widen the trust surface (the admin is already
    all-powerful via `currentImplementation`); the dropped trade-off is that the authorization _rules_
    (permissionless sync, proof-gated root) are no longer immutable.
12. **Tron support.** Tron is **in scope (D18)**. **Resolved:** Tron addresses need **not** match the
    EVM addresses — a Tron deposit address is its own thing. So Tron gets a **separate Tron factory**
    (mirroring the base `CounterfactualDepositFactoryTron`) and **Tron-specific implementations where
    needed** — principally the USDT / `safeTransfer` issue (Tron USDT doesn't return a bool, so use the
    `SafeTransferERC20` / `TronTransferLib` pattern). The **Tron factory is reworked**:
    `CounterfactualDepositFactoryTron` now extends the `ERC1967Proxy`-based factory and overrides only
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
      decide how the factory / bootstrap / `UpgradeRegistry` reach known Tron addresses (so prediction
      is meaningful), and deploy bootstrap + registry on Tron.
    - **(d) UUPS / ERC-1967 upgrade semantics.** Conceptually fine (TVM has `delegatecall`,
      `EXTCODESIZE`, the ERC-1967 slot) but unproven: deploy→finalize→upgrade must be tested on
      Shasta/Nile, including the `ERC1967Utils` code-size check.
    - **(e) Native asset (TRX / WTRX).** The SpokePool `NATIVE_ASSET` path wraps to `wrappedNativeToken`
      (WTRX on Tron, 6-decimal TRX) — needs Tron-specific config, or disable native for Tron routes.
    - **Already handled:** 0x41 CREATE2 prefix (factory override); USDT non-standard `transfer` return
      (the `_safeTransfer` hook in the Tron route/withdraw variants); `ecrecover` (works, given the
      signer signs with Tron's chainId per (b)).

13. **Beacon proxy instead of UUPS + bootstrap?** A `BeaconProxy` reading its implementation from the
    `UpgradeRegistry` (as `IBeacon`) would eliminate the bootstrap, `syncImplementation`, the finalize
    step, and version-counter machinery — proxies would run the latest impl by construction (the
    strongest form of "require latest"). **Decided for now (D23): keep UUPS + bootstrap.** Blocker is
    deploy cost: OZ's stock `BeaconProxy` runtime is ~287 bytes vs `ERC1967Proxy`'s ~100 (its
    `_implementation()` is an external `STATICCALL`, not an `SLOAD`) → **~+37k gas per counterfactual
    deployment** (200 gas/byte), only ~2k offset by skipping finalize; per-call cost is ~equal in a
    "require-latest" design. Revisit if (a) we adopt a minimal custom beacon proxy (~80 bytes assembly,
    which erases the deploy penalty), or (b) per-address deploy cost stops mattering. Note: switching
    commits to mandatory/immediate/global impl upgrades (reverses D13).

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
  upgrades by the global `UpgradeRegistry`. _Why:_ removes a per-proxy trusted key and concentrates the
  single trust point in the registry.
- **D4 — Address = `f(initialRoot)`; identity baked into the tree.** `initialRoot` (in init code, written
  to `activeRoot`) commits a tree carrying every source chain's route to one destination identity
  `(finalRecipient, outputToken, destinationChainId)`. _Why:_ identical `initialRoot` on every chain ⇒
  same address everywhere for a destination identity; per-chain routes differ but share one root (the
  caller proves the leaf for its chain).
- **D5 — Bootstrap deployment keeps the real impl out of the address.** Proxies deploy against a
  permanent, minimal bootstrap impl, then `syncImplementation()` upgrades to the registry's
  `currentImplementation()`. _Why:_ we don't want the versioned implementation to affect the address; the
  bootstrap is a fixed anchor so the real impl can change freely. Only the bootstrap (a constant) is in
  the CREATE2 preimage.
- **D6 — Finalize via global `currentImplementation()`, no proof.** The first `syncImplementation()`
  reads the registry's `currentImplementation()` directly. _Why:_ the value comes from the trusted
  registry; requiring a per-proxy proof just to deploy would need a leaf for every (possibly
  never-deployed) counterfactual.
- **D7 — Implementation upgrades global; roots per-proxy.** Implementation is administered once globally
  (`currentImplementation`); any proxy syncs to it permissionlessly (no proof — can only land on the
  current value; monotonic via a single slot). Roots are per-proxy via `updateRoot(newRoot, proof)`
  against the registry's `(proxy, latestRoot)` tree; the leaf carries **no** implementation. _Why:_
  implementation is shared logic (per-proxy admin would mean republishing a leaf per proxy to bump it);
  roots are inherently per-proxy (each encodes a unique identity's routes). _Rejected:_ a per-proxy impl
  override for canary/staggered rollout, for simplicity.
- **D8 — Registry handle is immutable in impl bytecode.** The `UpgradeRegistry` address is an
  immutable/constant in the bootstrap and impls, not proxy state. _Why:_ it's a global per-chain
  constant; per-proxy storage would waste an `SSTORE`/`SLOAD` and bloat init code. Migratable via the
  normal upgrade path if ever needed.
- **D9 — Registry (with factory + bootstrap) is same-address on every chain.** _Why:_ the bootstrap
  embeds the registry and is itself in the proxy preimage (`registry → bootstrap → proxy`), so the
  registry must be chain-invariant for address parity. (The real impl is the only piece exempt.)
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
- **D13 — `execute` requires the proxy to be up to date (supersedes the earlier "optional" stance).**
  `execute` (the deposit/withdraw path) gates on `_requireUpToDate()`:
  - **Implementation must be current** — `ERC1967Utils.getImplementation() == registry.currentImplementation()`
    (else `StaleImplementation`); exact address match, no impl version counter needed.
  - **Root must be recent enough** — the registry has a `version` (bumped on every `setUpgradeRoot`) and an
    admin-set `minRequiredVersion (<= version)`; each proxy stores a `rootVersion` and `execute` requires
    `rootVersion >= minRequiredVersion` (else `StaleRoot`). `rootVersion` is stamped on `updateRoot`
    (= `registry.version()`) and at deploy (D26).
  - **Remediation is permissionless and ungated:** `syncImplementation()` (impl) and `updateRoot()` (root)
    are never gated, so a stale proxy can always be brought current (then execute). The `updateRoot`
    no-op guard is relaxed to allow re-applying the _same_ root when it advances the version (so an
    unaffected proxy can still climb to a higher `minRequiredVersion`); only same-root-AND-same-version
    reverts.
    _Why:_ lets the admin force a security-critical impl fix or route retirement to actually take effect
    (a stale proxy can't keep depositing on old logic / a retired root). _Cost:_ ~one registry read for
    `(currentImplementation, minRequiredVersion)` per `execute`, plus the per-bump sync friction (each
    proxy must be synced/updated before its next deposit). Resolves Q9 + Q10.
- **D26 — Fresh proxy stamped at the registry's current `version` on deploy.** `initialize` sets
  `rootVersion = registry.version()`. _Why:_ a freshly deployed proxy is in no published upgrade tree, so
  it couldn't `updateRoot` to climb to `minRequiredVersion`; stamping it current makes it born executable
  (and `minRequiredVersion <= version` always holds). _Accepted limitation:_ a proxy whose `initialRoot`
  was _issued_ before a route was retired but _deployed_ after still executes that route once on
  `initialRoot` (it's stamped current at deploy) — mitigated off-chain (don't issue `initialRoot`s with a
  retired route) and, for a true emergency, by a route/impl-level disable rather than the version gate.
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
- **D19 — `UpgradeRegistry` is upgradeable (UUPS); no timelock in this implementation.** It needs a
  permanent address anyway (the bootstrap embeds it), so a UUPS proxy keeps the address fixed while
  logic can evolve. _Why no timelock:_ explicit scope decision for this first implementation —
  accepting that the admin is all-powerful (`currentImplementation` + permissionless sync) with no
  on-chain user-exit window. Known residual risk; revisit later. Resolves Q11.
- **D20 — Token model: per-input-token leaves; native via `NATIVE_ASSET`.** A distinct input token on a
  source chain is its own route leaf; the impl sweeps that leaf's input token, with native ETH via the
  `NATIVE_ASSET` sentinel where the bridge supports it — following the
  `taylor/counterfactual-route-policy` branch. EIP-712 domain `version = "v2.0.0"` (same branch).
- **D21 — The upgradeable contracts reuse the immutable names and replace that system.** No new
  `Dispatcher`/`Upgradeable*` contract names: `CounterfactualBase` (the UUPS base),
  `CounterfactualDeposit` (the dispatcher / registry `currentImplementation`), and
  `CounterfactualDepositFactory` (the UUPS factory) take over the existing names, alongside
  `CounterfactualBootstrap` + `UpgradeRegistry`; all in `contracts/periphery/counterfactual/`. _Why:_
  this upgradeable design _is_ the counterfactual system, not a parallel variant. _Consequence:_ the old
  immutable-system tests, deploy scripts, and the Clones-based `CounterfactualDepositFactoryTron` are
  superseded and **left broken for now**, to be rebuilt in Phase 4 / Phase 5 / Q12.
- **D22 — Reject no-op upgrades.** Both knobs revert if unchanged: `_authorizeUpgrade` reverts
  `ImplementationUnchanged` if the target equals the in-use implementation (covers `syncImplementation`
  and any direct `upgradeToAndCall`), and `updateRoot` reverts `RootUnchanged` if `newRoot == activeRoot`.
  _Why:_ avoids redundant state writes, event spam, and a wasted upgrade call.
- **D23 — Keep UUPS + bootstrap; don't switch to a beacon (provisional).** _Why:_ OZ's stock
  `BeaconProxy` runtime is ~187 bytes larger than `ERC1967Proxy` (its `_implementation()` is an external
  `STATICCALL`, not an `SLOAD`), ≈ +37k gas per counterfactual deployment — not worth the simplification
  given deploys recur across many addresses. The beacon stays an open alternative (Q13), attractive only
  with a minimal custom proxy.
- **D24 — Accept `AdminWithdrawManager.signedWithdraw` replayability as-is.** No nonce / used-marking;
  the signature is replayable within its `deadline`. _Why:_ the recipient is forced to the committed
  `user`, so a replay can only re-pay the rightful user (not theft); not worth the extra storage/used-map.
  (Was Q6.)
- **D25 — No on-chain root-version monotonicity; rely on an off-chain invariant.** `updateRoot` stays
  permissionless and version-less. Downgrade-to-a-retired-root is prevented by (i) registry-root
  rotation invalidating old trees, and (ii) a tree-generator invariant of **≤1 `(proxy, root)` leaf per
  proxy** per tree. _Why:_ the invariant is natural and the admin is already trusted; keeps version
  counters out (D13). _Risk accepted:_ a tooling slip would let anyone roll a proxy back to a stale root
  via the permissionless `updateRoot` — the tree builder must lint/enforce the invariant. (Was Q3.)
