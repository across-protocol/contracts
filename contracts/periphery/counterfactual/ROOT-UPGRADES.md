# Root Upgrades — Backend Runbook

Operational companion to [DESIGN.md](./DESIGN.md). This describes the end-to-end process for
upgrading the `activeRoot` (route set) of **all deployed counterfactual proxies**, to be executed by
the backend team. Read DESIGN.md §_Upgrade Mechanism_ first for the why; this is the how.

## What a root upgrade is (and is not)

Each counterfactual `BeaconProxy` stores one mutable value: `activeRoot`, the merkle root of its
**Route Tree** (the routes it may execute). Upgrading roots means moving each proxy's `activeRoot`
to a new Route Tree root. It does **not** touch the proxy's address (bound to `initialRoot`
forever), and it is **not** the mechanism for logic changes — that is the global
`setImplementation` on the beacon, which needs no per-proxy action.

Two on-chain surfaces are involved:

| Contract                       | Address                                                                                                       | Role in a root upgrade                                                                     |
| ------------------------------ | ------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------ |
| `CounterfactualBeacon` (proxy) | `0xB7eBaD46Ae4Ccbd0d9676ee1A34Ceb0136388133` on every EVM chain; `THPzGxABJ21dckZ5oGc3QScESL2mNnnqSx` on Tron | Owner-gated `setUpgradeRoot(bytes32)` publishes the per-chain **Upgrade Tree** root        |
| Each counterfactual proxy      | per-identity (factory CREATE2, same address every chain)                                                      | Permissionless `updateRoot(newRoot, proof)` / `updateRootAndExecute(...)` applies its leaf |

The process is therefore **two-phase**:

1. **Publish** (admin, one multisig tx per chain): set the beacon's `upgradeRoot` to a new Upgrade
   Tree that commits every proxy's latest Route Tree root.
2. **Apply** (permissionless, one call per proxy per chain): prove each proxy's
   `(proxy, latestRoot)` leaf and set its `activeRoot`. Any funded EOA can do this — the proof is
   the authorization.

Root updates are **best-effort**: a proxy keeps its old `activeRoot` until phase 2 reaches it.
Nothing on-chain forces phase 2; the backend owns completion tracking.

> **⚠️ Late deployments always use the original `initialRoot` — never an upgraded root.** A root
> upgrade changes what a proxy's `activeRoot` should be; it never changes what you _deploy_. When an
> identity's proxy must be deployed on a further chain (funds arrived at its canonical address there,
> or `deployIfNeededAndExecute` fires), the deployment **must** use the exact `(initialRoot, salt)`
> from issuance, even when newer Route Tree roots exist — `initialRoot` is embedded in the CREATE2
> init code, so it alone reproduces the identity's canonical cross-chain address. Deploying with a
> newer root does not revert; it silently creates a **different address** that is nobody's identity,
> while the funds at the canonical address stay counterfactual and stranded until someone deploys it
> correctly. The correct flow is always: deploy with `initialRoot`, then bump `activeRoot` to
> `latestRoot` (atomically via `updateRootAndExecute`, whose Upgrade Tree leaf exists for exactly
> this — see _Include undeployed identities_ below). Backend rule: persist each identity's
> issuance-time `(initialRoot, salt)` forever and treat it as the only valid deploy input on any
> chain.

---

## Phase 0 — Build the trees off-chain

### 0.1 New Route Tree per identity

For each counterfactual identity, build its new Route Tree exactly as at issuance
(OpenZeppelin `StandardMerkleTree`, leaf type `["address", "bytes32"]` =
`(implementation, keccak256(params))`). Leaves are chain-agnostic, so **one Route Tree root per
identity, valid on every chain**. Its root is that proxy's `latestRoot`.

### 0.2 The Upgrade Tree

Build the Upgrade Tree with the same library and encoding:

```ts
import { StandardMerkleTree } from "@openzeppelin/merkle-tree"

// values: [proxyAddress, latestRouteTreeRoot]
const tree = StandardMerkleTree.of(values, ["address", "bytes32"])
const upgradeRoot = tree.root // -> setUpgradeRoot(upgradeRoot)
const proof = tree.getProof([proxy, latestRoot]) // -> proxy.updateRoot(latestRoot, proof)
```

On-chain verification recomputes
`leaf = keccak256(bytes.concat(keccak256(abi.encode(address(this), newRoot))))` — the
StandardMerkleTree double-hash. A single-hashed or differently-encoded tree produces proofs that
**never verify** (`InvalidUpgradeProof`); there is no partial failure mode to detect this other
than the revert.

**Construction rules (all load-bearing):**

- **One leaf per proxy, always its latest root.** A second (older) leaf for the same proxy is a
  live downgrade path — the no-downgrade invariant exists only in tree construction, not on-chain.
- **The tree is cumulative, not a delta.** `setUpgradeRoot` _replaces_ the previous tree and
  invalidates every outstanding proof against it. The new tree must therefore contain a leaf for
  **every** proxy whose `activeRoot` may still need to move — including proxies from earlier
  batches that were never bumped (phase 2 is best-effort) and identities **not yet deployed** on
  some chains. Dropping a leaf silently strands that proxy on its current root until a future tree
  re-includes it.
- **Include undeployed identities.** A proxy deployed later (e.g. via
  `deployIfNeededAndExecute`) is always deployed with — and initializes to — its **original**
  `initialRoot`, no matter how many upgrades happened meanwhile (deploying with anything else
  produces the wrong address — see the ⚠️ callout above). Keeping its `(futureAddress,
latestRoot)` leaf in the tree permanently is the other half of that invariant: it lets the
  deploy-time flow bump the fresh proxy to `latestRoot` immediately via `updateRootAndExecute`.
- **One canonical tree is fine for all chains.** `latestRoot` is chain-invariant and proxy
  addresses match across chains, so the simplest correct policy is a single global
  `(proxy → latestRoot)` mapping published identically to every chain's beacon. Per-chain trees
  with different proxy subsets are allowed by the design but add bookkeeping for no benefit —
  a leaf for a proxy with no code on some chain is inert there.

### 0.3 Enumerate the proxy set

Source of truth is the backend's own registry of issued identities. Cross-check on-chain via the
factory's `CounterfactualDeployed(address counterfactual, bytes32 initialRoot)` events:

- EVM factory: `0x9F62dcc4B939485911C4f9b24BdCa4324D6b97d1` (same address, all EVM chains)
- Tron factory (`CounterfactualDepositFactoryTron`): `TUoGXCRHSeAVTVBkdqHMbtNpxj19yXGUuB`

For each proxy, record per chain: deployed? current `activeRoot()`? (A proxy can be deployed on
chain A and still counterfactual on chain B — both states need the leaf, only the deployed one
gets a phase-2 tx.)

> **Scroll (534352) is out of scope.** Its counterfactual deployment predates the beacon system
> (no `CounterfactualBeacon` on that chain); those clones are not root-upgradeable.

---

## Phase 1 — Publish: `setUpgradeRoot` on every chain's beacon

`setUpgradeRoot(bytes32)` is `onlyOwner` on the beacon (`Ownable2Step`; owners are the per-chain
multisigs in `script/counterfactual/config.toml` `ownerAndDirectWithdrawer`, cross-referenced in
`script/mintburn/prod-readiness-multisigs.json` — mainnet uses a different multisig than most L2s;
Lens/zkSync differ again).

Per chain, queue a multisig tx:

- **To:** `0xB7eBaD46Ae4Ccbd0d9676ee1A34Ceb0136388133`
- **Data:** `cast calldata "setUpgradeRoot(bytes32)" <upgradeRoot>`

Because signers approve an opaque `bytes32`, ship a **reproducible derivation** with every
proposal: the full `(proxy, latestRoot)` value dump plus the script/commit that rebuilds the root,
so any signer can regenerate and diff it. This root authorizes arbitrary route-set changes for
every listed proxy — treat review with the same weight as an implementation upgrade.

Tron: same call on `THPzGxABJ21dckZ5oGc3QScESL2mNnnqSx`, sent via TronWeb (Foundry cannot
broadcast to Tron — model on the existing `script/tron/counterfactual/*.ts` scripts).

**Sequencing:** finish (or pause) any in-flight phase-2 submissions for the _previous_ tree before
executing `setUpgradeRoot` on a chain — old proofs revert `InvalidUpgradeProof` the moment the root
changes (harmless but noisy). Chains are independent; no cross-chain ordering constraint exists.
Verify with `cast call <beacon> "upgradeRoot()(bytes32)"` per chain before starting phase 2.

---

## Phase 2 — Apply: `updateRoot` fan-out per proxy

For every **deployed** proxy whose on-chain `activeRoot()` ≠ its `latestRoot`, send:

```
proxy.updateRoot(latestRoot, proof)   // proof from the new Upgrade Tree, phase 0.2
```

Operational notes:

- **Permissionless and sender-independent** — use any funded hot wallet; no signature or role
  needed beyond the proof.
- **Batch via Multicall3.** `updateRoot` has no `msg.sender` dependence, so
  `aggregate3` with `allowFailure: true` batches hundreds of proxies per tx. `allowFailure`
  matters: a proxy already at `latestRoot` reverts `RootUnchanged` (e.g. a race with a relayer's
  `updateRootAndExecute`), and one such revert must not poison the batch.
- **Pre-filter by reading `activeRoot()`** (multicall the reads too) to keep batches tight; treat
  `RootUnchanged` as success in reconciliation.
- **Skip undeployed proxies** — nothing to call; their leaf waits in the tree for the
  deploy-time `updateRootAndExecute` path.
- **Prioritize by balance.** Since updates are best-effort, sweep proxies holding funds first;
  idle proxies can be lazily bumped by the relayer's `updateRootAndExecute` at their next
  execution.
- **Tron** proxies need the same call through TronWeb.

**Failure modes:** `InvalidUpgradeProof` = wrong tree/encoding/stale proof (regenerate against the
root actually on the beacon); `RootUnchanged` = already current (fine). There are no other revert
paths in `_updateRoot`.

### The lazy path (why leaves must persist)

Relayers/executors call `updateRootAndExecute(newRoot, updateProof, impl, params, submitterData,
executeProof)` to bump-and-deposit atomically; it skips the update (and skips validating
`updateProof`) when the proxy is already at `newRoot`. The backend quote/proof service must
therefore serve, for every identity: its `latestRoot`, its Upgrade Tree proof (per chain), and
route proofs against the **new** Route Tree. Serving a route proof against the old tree after the
proxy was bumped makes `execute` revert `InvalidProof` — cut the proof service over to the new
Route Trees per proxy as each proxy is confirmed bumped, or key proofs by observed `activeRoot`.

Note: outstanding **fee signatures are not invalidated** by a root change (they bind
`routeParamsHash`, not the root) — a leaf present in both old and new trees keeps working across
the upgrade with fresh proofs.

### Backend API surface (required)

Proofs exist nowhere on-chain — only roots do — and `updateRoot` is authorized solely by the
proof. So the backend **must expose a proof endpoint**; without it neither the phase-2 fan-out nor
the lazy deploy-time path can construct a valid call. For each identity it serves:

| Field                 | What                                                            | Keyed by                                              |
| --------------------- | --------------------------------------------------------------- | ----------------------------------------------------- |
| `latestRoot`          | the identity's current Route Tree root (chain-invariant)        | identity                                              |
| upgrade proof         | merkle proof for the `(proxy, latestRoot)` Upgrade Tree leaf    | the `upgradeRoot` **observed on that chain's beacon** |
| route proofs          | proofs for the identity's leaves against its **new** Route Tree | the proxy's **observed `activeRoot`**                 |
| `(initialRoot, salt)` | issuance-time deploy inputs (see the ⚠️ callout)                | identity, immutable                                   |

Key by observed on-chain state, not by "latest published": during a rollout, chains transiently
hold different `upgradeRoot`s (a proof against the wrong tree reverts `InvalidUpgradeProof`), and a
route proof against a tree that doesn't match the proxy's current `activeRoot` reverts
`InvalidProof`. An `updateRootAndExecute` caller needs the upgrade proof **and** the new-tree route
proof in one payload.

---

## Phase 3 — Verify and reconcile

For every chain:

1. `beacon.upgradeRoot()` equals the published root.
2. For every deployed proxy: `activeRoot()` equals its `latestRoot` (multicall reads), and/or
   index `RootUpdated(bytes32 newRoot)` events emitted by each proxy.
3. Persist the reconciliation result — the set of not-yet-bumped proxies is exactly the set whose
   leaves **must** be carried into the next Upgrade Tree.

`script/counterfactual/CheckCounterfactualDeployments.s.sol` verifies the infra (beacon config,
owners, leaf impls) across all chains and is a good pre-flight before phase 1; it does not check
per-proxy roots.

---

## Quick reference

| Step                             | Actor                | Call                                                                                            | Gate                                     |
| -------------------------------- | -------------------- | ----------------------------------------------------------------------------------------------- | ---------------------------------------- |
| Build Route Trees + Upgrade Tree | backend              | `StandardMerkleTree.of(..., ["address","bytes32"])`                                             | encoding must match on-chain double-hash |
| Publish                          | per-chain multisig   | `beacon.setUpgradeRoot(root)`                                                                   | `onlyOwner`                              |
| Apply (eager)                    | any EOA / Multicall3 | `proxy.updateRoot(latestRoot, proof)`                                                           | merkle proof                             |
| Apply (lazy / at deploy)         | relayer              | `proxy.updateRootAndExecute(...)` / factory `deployIfNeededAndExecute` → `updateRootAndExecute` | merkle proof                             |
| Verify                           | backend              | `upgradeRoot()`, `activeRoot()`, `RootUpdated`                                                  | —                                        |
