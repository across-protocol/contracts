# Route Policies — Design Specification

A lighter architecture for counterfactual addresses that separates _what an address is_ from _what routes it can execute_, and lets entire groups of addresses upgrade together on a chain with a single transaction.

This document is an implementation specification. Starting point: the original counterfactual contracts on `master` (no prior upgradability work). All contract changes and additions described here are deltas against that baseline.

---

## Table of Contents

- [Goals](#goals)
- [Architecture Overview](#architecture-overview)
- [What is a policy?](#what-is-a-policy)
- [Clone immutable args](#clone-immutable-args)
- [RoutePolicy contract](#routepolicy-contract)
- [CounterfactualDeposit (dispatcher)](#counterfactualdeposit-dispatcher)
- [Bridge implementations](#bridge-implementations)
- [WithdrawImplementation](#withdrawimplementation)
- [Leaf format & off-chain tree construction](#leaf-format--off-chain-tree-construction)
- [Cross-chain address consistency](#cross-chain-address-consistency)
- [Deployment](#deployment)
- [Implementation plan](#implementation-plan)
- [Open questions](#open-questions)

---

## Goals

1. **Persistent, evolvable addresses.** An address is keyed solely to `(outputToken, destinationChainId, recipient, userAddress, routePolicyAddress)` and never needs to change. The routes it can execute can evolve without regenerating the address.
2. **Same address on every EVM chain** for a given identity + policy.
3. **Global upgrade per chain per policy.** One root rotation per chain upgrades every clone using that policy on that chain. No per-clone upgrade transaction. Rotation is performed by the policy owner via `upgradeToAndCall` — deploying a new implementation with the new root baked in and pointing the proxy at it.
4. **Independent integrator lifecycles.** Different policies are owned and upgraded independently of each other.
5. **Dynamic execution fees.** The executor supplies `executionFee` at execute time; a signer's EIP-712 signature authorizes it. Applies uniformly to **SpokePool, CCTP, and OFT** implementations.
6. **Bounded trust.** The policy owner is a meaningful authority but cannot redirect destination, output token, or recipient (clone immutables guard those). Fee bounds are committed in the merkle tree. The clone's `userAddress` retains a structurally-guaranteed escape — full execution authority over the clone, bypassing the policy entirely. The `AdminWithdrawManager`'s `signedWithdraw` path forces withdrawal recipient to `cloneArgs.userAddress`, so the lower-trust `signer` role can authorize a withdrawal but cannot redirect funds. The trusted `directWithdrawer` retains recipient-choice freedom.

---

## Architecture Overview

```
Deployer / SDK
       │
       │ CREATE2 via deterministic-deployment proxy
       ▼
┌──────────────────────────────────────────────────────────────┐
│ Clone (EIP-1167 proxy, ~77 bytes total)                      │
│ Immutable arg (single 32-byte slot):                         │
│   argsHash = keccak256(abi.encode(                           │
│     outputToken, destinationChainId, recipient,              │
│     userAddress, routePolicyAddress                   │
│   ))                                                         │
└──────────────────────────────────────────────────────────────┘
       │
       │ delegatecall (via EIP-1167) — caller supplies the 5 args in calldata
       ▼
┌──────────────────────────────────────────────────────────────┐                ┌──────────────────────────────────────────┐
│ CounterfactualDeposit (dispatcher, no per-clone state)       │  staticcall    │ RoutePolicyImmutableRoot (UUPS proxy)    │
│   - verifies keccak256(args) == clone.argsHash               │ ─────────────► │   - owner: Across or integrator multisig │
│   - if msg.sender == args.userAddress: skip merkle check     │   activeRoot   │   - root: immutable on the impl, baked   │
│   - else: verifies merkle proof against policy root          │ ◄───────────── │     chain's 4-dim route-leaf tree        │
│   - delegatecalls impl with verified args                    │     bytes32    │   - rotate via upgradeToAndCall to a new │
│                                                              │                │                                          │
└──────────────────────────────────────────────────────────────┘                └──────────────────────────────────────────┘
       │
       │ delegatecall
       ▼
┌──────────────────────────────────────────────────────────────┐
│ Bridge implementation (SpokePool / CCTP / OFT / Withdraw)    │
│   - verifies signer EIP-712 over runtime fields              │
│   - constructs the bridge call using clone immutables for    │
│     destination identity                                     │
└──────────────────────────────────────────────────────────────┘
       │
       │ external CALL
       ▼
┌──────────────────────────────────────────────────────────────┐
│ Underlying bridge contract                                   │
│   (Across SpokePool, SponsoredCCTPSrcPeriphery,              │
│    SponsoredOFTSrcPeriphery, or ERC-20 / native transfer     │
│    in the withdraw case)                                     │
└──────────────────────────────────────────────────────────────┘
```

---

## What is a policy?

A policy is a deployed `RoutePolicyImmutableRoot` proxy instance. Each one exposes an `activeRoot(clone)` view returning the merkle root of a tree enumerating every route the policy authorizes on this chain. The root itself is `immutable` on the implementation contract behind the proxy; rotating it requires a UUPS upgrade. An `owner` (typically a multisig) holds upgrade authority and is the only party that can rotate the root.

The policy's content lives off-chain in the merkle tree; the on-chain state is just the root and the owner. A policy is the unit of governance: one owner runs it, one approval upgrades it, one address identifies it.

Clones reference a specific policy via their `routePolicyAddress` immutable arg. Every clone pointing at the same policy shares the same authorized routes and rotates together. A clone is bound to one policy for life — switching policies requires generating a new address (different `routePolicyAddress` → different CREATE2).

Multiple policies can coexist on the same chain. As one example deployment shape:

- **Default policy** — owned by the Across multisig. Holds the canonical set of routes.
- **Per-integrator policies** — an integrator or institutional partner deploys their own `RoutePolicyImmutableRoot` proxy with their own bridge whitelist, fee caps, and supported destinations.
- **Experimental policy** — a beta route set for early adopters to opt into.

The contracts impose no constraints on how many policies exist or who runs them; the above is illustrative.

---

## Clone immutable args

Each clone's bytecode appends a single 32-byte immutable argument after the EIP-1167 proxy bytecode:

```
argsHash = keccak256(abi.encode(
  outputToken, destinationChainId, recipient, userAddress, routePolicyAddress
))
```

The five underlying fields are:

| Field                | Type      | Description                                                                                                                                                                                                                                                |
| -------------------- | --------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `outputToken`        | `bytes32` | Token received on the destination chain. `bytes32` to support non-EVM tokens.                                                                                                                                                                              |
| `destinationChainId` | `uint256` | Destination chain ID (or a canonical Across-assigned ID for non-EVM destinations).                                                                                                                                                                         |
| `recipient`          | `bytes32` | Destination-chain address that receives `outputToken`.                                                                                                                                                                                                     |
| `userAddress`        | `address` | EVM address representing the clone's user. The canonical authority — can call any impl with any routeParams via the dispatcher's user escape, bypassing the policy's merkle-proof check. Also the forced destination for `WithdrawImplementation` payouts. |
| `routePolicyAddress` | `address` | The `RoutePolicy` that authorizes which routes this clone can execute.                                                                                                                                                                                     |

The caller passes all five values in calldata at execute time; the dispatcher recomputes `keccak256(abi.encode(args))`, asserts it equals the clone's stored `argsHash`, and then forwards the now-verified args into the bridge implementation. Tamper-proofness comes from the hash check, not from a signature — once the hash matches, the args are as authoritative as if they were stored in clone bytecode directly.

**Why hash-of-args rather than storing the five fields directly.** Storing only the hash shrinks the appended args from ~160 bytes to 32 bytes, saving ~25k gas per clone deployment. The trade is roughly ~2k extra calldata gas per execute (passing the five fields in) plus one keccak256, which is a good deal for one-shot deposit clones (the dominant usage pattern) and only mildly worse for clones that get executed many times.

All five values still participate in CREATE2 address derivation — they're committed via the hash that appears in the clone's initcode, so two different identities produce two different clone addresses.

---

## RoutePolicy contract

`RoutePolicyImmutableRoot` is a UUPS-upgradeable, `Ownable` implementation of `IRoutePolicy`. The active merkle root lives in `bytes32 immutable _root` on the implementation contract — baked into the implementation's runtime bytecode at construction time, not in storage. `activeRoot(clone)` returns it directly with no `SLOAD`. The interface is intentionally minimal — `IRoutePolicy.activeRoot(address clone)` — leaving room for future implementations to vary the root per-clone without changing consumers. The V1 implementation ignores the `clone` argument and returns the single immutable root.

Because the root is immutable on the impl, "rotating the root" is a UUPS upgrade: the owner deploys a new implementation with the new root in its constructor and calls `upgradeToAndCall(newImpl, "")` on the proxy. The proxy's address is unchanged; only its ERC-1967 implementation slot moves. Off-chain indexers watch the standard `Upgraded(address newImpl)` event and read `activeRoot(...)` to learn the new root.

At genesis the implementation is constructed with `initialRoot = bytes32(0)`, and the proxy is initialized via `initialize(initialOwner)`. To make the proxy land at the same address on every chain (cross-chain consistency, see below), both the implementation's constructor arg and the proxy's init data must be identical across chains at genesis. `initialOwner` is a **deployer EOA** controlled by the party deploying the policy (Across, or an integrator deploying their own policy); ownership is transferred to the chain-local multisig as a post-deploy step. Chain-local multisigs are typically not at the same address across chains, which is why a deployer EOA — held by a single party and trivially identical across chains — is used as the bootstrap owner.

The deployer EOA holds full upgrade authority on the policy during the window between deployment and ownership transfer. Operationally this is mitigated by (a) using a hardware-wallet-backed key, (b) deploying and transferring ownership in the same campaign so the window is short, and (c) destroying / retiring the key after the deployment campaign — the key has no purpose after every policy on every chain has been transferred to its chain-local multisig.

Intentionally **not** included in V1 of `RoutePolicyImmutableRoot`:

- No timelock between root proposal and activation (timelock is still flagged in [open questions](#open-questions) as the mitigation for owner compromise / unauthorized upgrades).
- No separate upgrade role — the owner is also the upgrader. A future hardening would split these so day-to-day root rotations can be signed by a lower-trust multisig while truly arbitrary impl upgrades require a more conservative one.
- No multi-root grandfathering.
- No per-leaf governance.
- No per-clone root behavior in the V1 implementation. The interface accepts a `clone` argument so this can be added later as an upgrade without changing consumers.

---

## CounterfactualDeposit (dispatcher)

The dispatcher is the EIP-1167 target every clone delegatecalls into. It has no per-clone or per-call storage and no constructor args.

On `execute(cloneArgs, implementation, routeParams, submitterData, proof)`:

1. **Verify clone-args hash.** Fetch the clone's 32-byte immutable `argsHash`, recompute `keccak256(abi.encode(cloneArgs))`, and revert if they don't match. After this step, `cloneArgs` is as authoritative as if it had been stored directly in clone bytecode.
2. **User escape.** If `msg.sender == cloneArgs.userAddress`, skip the merkle proof entirely. The user has full execution authority over their own clone and can call any `implementation` with any `routeParams`. This guarantees the user can recover funds (or execute anything else) regardless of policy state — even if the policy contract is broken, missing, or its root is `bytes32(0)`.
3. **Merkle proof.** For non-user callers, reconstruct the leaf as `keccak256(bytes.concat(keccak256(abi.encode(implementation, keccak256(routeParams)))))` (double-hashed per the OZ standard), fetch `IRoutePolicy(cloneArgs.routePolicyAddress).activeRoot(address(this))`, and verify the proof. Revert if it doesn't verify. The dispatcher is agnostic to clone identity at the leaf level — each impl declares its own identity-binding semantics by what it puts in its `routeParams` struct. All current production impls (SpokePool, CCTP, OFT) commit `outputToken` and `destinationChainId` inside `routeParams` and verify them via `CloneIdentity.enforce(...)` at the top of `execute`; a future agnostic impl could omit those fields, but no current impl does.
4. **Delegatecall the implementation** with `(cloneArgs.recipient, cloneArgs.outputToken, cloneArgs.destinationChainId, routeParams, submitterData)`.

Step 1 is what makes step 3's binding meaningful — without the hash verification, an attacker could supply a fabricated `cloneArgs` and pick any leaf they liked.

The user escape's scope is intentionally broad: the user can pass any `implementation` (not just `WithdrawImplementation`) and any `routeParams`. This collapses what was previously a special-cased withdraw path into a single generic escape. The user's blast radius is already "drain everything" via any withdraw impl, so the broader capability adds no marginal compromise risk — but it does mean a compromised user key can run arbitrary code in the clone's context via delegatecall.

---

## CounterfactualDepositFactory

Deploys clones via CREATE2. The user-facing API accepts the five identity fields; internally the factory computes `keccak256(abi.encode(...fields))` and uses that 32-byte hash as the clone's immutable-args blob. Exposes `deploy`, `predict`, and combined deploy-and-execute entrypoints — `predictDepositAddress` takes the same five fields and returns the deterministic address.

`CounterfactualDepositFactoryTron` mirrors the same interface but uses the Tron-specific CREATE2 prefix. Tron clones derive to different addresses than EVM clones for the same identity — same as the original counterfactual contracts.

---

## Bridge implementations

The interface every impl implements is `execute(bytes32 recipient, bytes32 outputToken, uint256 destinationChainId, address userAddress, bytes calldata routeParams, bytes calldata submitterData)`. The dispatcher forwards the clone-identity fields impls may use — `recipient`, `outputToken`, `destinationChainId`, `userAddress` — after verifying them against the clone's stored `argsHash`. `routePolicyAddress` stays dispatcher-internal. Because every field that does reach the impl is dispatcher-verified, impls treat them as fully authoritative.

`userAddress` is forwarded specifically so impls can pin a clone-bound destination and / or allow the user direct execution authority. `WithdrawImplementation` uses it as the forced withdrawal destination and as one of two authorized callers (the other is its own immutable `admin`). Bridge impls accept the field and ignore it.

`WithdrawImplementation` conforms to the same interface but only uses `userAddress` (the destination and one of two valid callers) and `submitterData` (decoded as `(token, amount)`); the other identity fields and `routeParams` are accepted but ignored. The dispatcher doesn't special-case it — user-initiated invocations flow through the user escape; manager-initiated invocations flow through the merkle path. Both reach the same generic delegate path.

Four conventions apply across all bridge impls:

- **`routeParams` layout.** Each impl's `*RouteParams` struct begins with `(bytes32 outputToken, uint256 destinationChainId)` for identity binding, followed by impl-specific fields:
  - **`SpokePoolRouteParams`** — binding fields, then input token, fee caps, exchange rate, message. Binding is required because `stableExchangeRate` is a per-pair assumption.
  - **`CCTPRouteParams`** — binding fields, then CCTP-specific fields (`destinationDomain`, `mintRecipient`, `burnToken`, etc.). Binding required because the destination periphery routes directly to the bound output token.
  - **`OFTRouteParams`** — binding fields, then OFT-specific fields (`dstEid`, `destinationHandler`, etc.). Same reasoning as CCTP.
    Every impl calls `CloneIdentity.enforce(rp.outputToken, outputToken, rp.destinationChainId, destinationChainId)` at the top of `execute`. `recipient` never appears in any route-params struct — it's always read from `cloneArgs` at execute time.
- **Reads `cloneArgs` for user identity.** Recipients, output tokens, destination chain, and user authority come from the dispatcher-verified `cloneArgs`, never from caller-supplied `routeParams` or submitter data. The bridge call's `recipient` field is `cloneArgs.recipient`; the `finalToken` field is `cloneArgs.outputToken`.
- **Dynamic `executionFee` authorized by a local signer, hard-capped per leaf.** Every bridge impl (SpokePool, CCTP, OFT) carries its own `signer` immutable and validates an EIP-712 signature at execute time over a runtime `executionFee` (plus deadline and recipient). The fee is supplied in `submitterData`, not committed in the leaf, so it can move with market conditions. The cap on what the signer can authorize is per-impl: **CCTP and OFT** carry a fixed-amount `maxExecutionFee` field in their `routeParams` that hard-bounds `executionFee` directly. **SpokePool** reuses its existing `maxFeeFixed + maxFeeBps × inputAmount` cap on the combined `relayerFee + executionFee` total, which implicitly bounds `executionFee` (no separate field). In both cases a malicious signer cannot extract more than the cap committed via the merkle root. For CCTP and OFT, local signature validation is **new** — those impls had no local signer in the original contracts and gain one as part of this design. For SpokePool the existing local signer is extended to cover the dynamic fee.
- **Signer EIP-712 binds to the clone and the leaf.** Every signer signature is bound to `address(this)` (the clone) via the EIP-712 domain separator. **SpokePool** additionally includes `routeParamsHash = keccak256(routeParams)` in its typehash to pin the signature to a specific leaf. **CCTP and OFT** instead include `nonce` (from `submitterData`), which is also covered by the periphery's quote signature — together they pin the local sig to the specific `(route, nonce)` execution and provide single-use replay protection (once the periphery consumes the nonce, the local sig is unusable).

### SpokePool

Already had a local signer in the original contracts. This design adds:

- **Dynamic `executionFee`** — moved from `routeParams` into submitter data. The signer's EIP-712 message now includes `executionFee` so it cannot be inflated by the executor.
- **`routeParamsHash` in the signer typehash** — needed because a policy now contains multiple SpokePool leaves (different routes); signatures must not be reusable across leaves. (CCTP/OFT take a different approach — see those sections.)
- **`clone` in the signer typehash** — prevents signature reuse across clones with the same destination identity.
- **No separate `maxExecutionFee` cap.** The existing `maxFeeFixed + maxFeeBps × inputAmount` check on `relayerFee + executionFee` already bounds the executionFee implicitly (since `executionFee ≤ totalFee ≤ maxFee`). A separate per-leaf executionFee cap would be redundant.

### CCTP

In the original contracts CCTP had **no local signature validation** — it forwarded a periphery-issued quote signature unchanged. This design **adds local EIP-712 signature validation** whose sole job is to authorize the runtime `executionFee`:

- New `signer` constructor immutable.
- New typehash: `ExecuteCCTP(bytes32 nonce, uint256 executionFee, uint32 signatureDeadline)`. The clone is bound via the EIP-712 domain separator's `verifyingContract`; `amount` is bound via the periphery signature (which covers `depositAmount`); the route is bound transitively via `nonce`, since the periphery signature commits `(route, nonce)` together. Binding to `nonce` also gives single-use replay protection — once the periphery consumes the nonce, the local sig is unusable.
- New submitter-data fields: `executionFee`, `executionFeeRecipient`, `signatureDeadline`, `counterfactualSignature` (local signer) alongside the existing `peripherySignature` (forwarded periphery quote).
- New `routeParams` field: `maxExecutionFee`, a fixed-amount cap that hard-bounds the runtime `executionFee` for this route. The signer can choose any value `≤ maxExecutionFee`; values above revert.

The CCTP periphery's existing quote signature is still required and forwarded unchanged. Two signatures are checked per execute: the periphery signature (route + amount) and the new local signature (runtime fee).

### OFT

Same pattern as CCTP — **adds local EIP-712 signature validation** that didn't previously exist on this impl, along with the EIP-712 typehash, submitter-data fields, and `maxExecutionFee` `routeParams` field (fixed-amount cap on the runtime `executionFee`). The OFT periphery's existing quote signature continues to be required and forwarded unchanged.

`msg.value` is still forwarded to the OFT periphery to cover LayerZero native messaging fees.

---

## WithdrawImplementation

A standard `ICounterfactualImplementation` that decodes `submitterData` as `(token, to, amount)` and transfers the specified token (or native ETH) to `to`. The clone-identity fields (`recipient`, `outputToken`, `destinationChainId`) and `routeParams` are accepted but ignored.

WithdrawImplementation self-protects by checking `msg.sender ∈ {admin, userAddress}` internally — where `admin` is an immutable on the impl (typically the `AdminWithdrawManager`) and `userAddress` is the dispatcher-forwarded `cloneArgs.userAddress`. The destination is always `userAddress`; `submitterData` decodes as `(token, amount)`, not `(token, to, amount)`.

Two invocation paths reach the impl:

- **User self-withdraw**: the user calls `clone.execute(..., withdrawImpl, ..., [])`. The dispatcher's user escape (`msg.sender == cloneArgs.userAddress`) skips the merkle proof. The impl's caller check passes via the `userAddress` arm.
- **Manager-driven withdraw**: `AdminWithdrawManager` (the impl's immutable `admin`) calls `clone.execute(..., withdrawImpl, ..., proof)`. The dispatcher verifies the proof against a policy tree containing the withdraw leaf. The impl's caller check passes via the `admin` arm.

Recipient handling differs per path: the `directWithdrawer` (trusted role) chooses the recipient freely; the `signer` (semi-trusted hot role) cannot — `signedWithdraw` forces the recipient to `cloneArgs.userAddress`. So a compromised `signer` can force a withdrawal to happen but cannot redirect funds.

`WithdrawImplementation` is deployed deterministically with no constructor args — same address on every EVM chain. The dispatcher does not pin it via an immutable; admins choose to invoke it (or any other impl) when they want to sweep funds.

`AdminWithdrawManager` is the recommended `WithdrawImplementation.admin` for production deployments. The impl is constructed with the manager's address; the manager itself has no impl reference at construction — `withdrawImpl` is a per-call argument on `directWithdraw(depositAddress, cloneArgs, withdrawImpl, token, recipient, amount, proof)` and `signedWithdraw(depositAddress, cloneArgs, withdrawImpl, token, amount, deadline, signature, proof)`. Both paths call `clone.execute(cloneArgs, withdrawImpl, "", abi.encode(token, recipient, amount), proof)` — for `directWithdraw` the `recipient` is caller-supplied; for `signedWithdraw` the manager substitutes `cloneArgs.userAddress` as the recipient. The dispatcher verifies the proof; the impl's `admin == manager` arm of the caller check passes; funds land at the encoded recipient. The signed path's typehash is `SignedWithdraw(address depositAddress, address withdrawImpl, address token, uint256 amount, uint256 deadline)` — recipient is omitted because the manager forces it; impl address is signed so a submitter cannot redirect an authorized withdrawal to a different impl.

The "manager has no immutable impl" choice breaks what would otherwise be a circular construction dependency (impl's `admin` immutable wants the manager address; manager's `withdrawImpl` immutable would want the impl address). Deployment is just: deploy the manager first (its constructor args don't depend on the impl), then deploy `WithdrawImplementation(managerAddress)`. Both are deterministic across chains via Nick's factory.

---

## Leaf format & off-chain tree construction

Each leaf is computed as `keccak256(bytes.concat(keccak256(abi.encode(bridgeImpl, keccak256(routeParams)))))`. The outer `keccak256(bytes.concat(...))` provides the OZ-standard double-hash (preventing leaf/internal-node ambiguity in the merkle proof); the inner `keccak256(abi.encode(bridgeImpl, keccak256(routeParams)))` commits to the bridge impl address alongside the params hash. `routeParams` is itself pre-hashed because it's a variable-length bytes blob — packing it through abi.encode as-is would still work but yields a longer preimage for no benefit. `bridgeImpl` is chain-specific (different per-chain immutables → different addresses), so each chain's tree naturally includes only that chain's impls.

`block.chainid` is **not** in the leaf preimage. Per-chain `RoutePolicyImmutableRoot` enforces chain-specificity automatically — a leaf committed to chain A's root cannot be proven against chain B's root because the roots are different values (each chain has its own implementation with its own immutable root).

Each chain's policy tree enumerates a **4-dimensional cross-product**: `inputToken × bridge × destinationChainId × outputToken`. Every current impl binds identity, so each combination is its own leaf. The dimensions are:

- **`inputToken`** — the token the user funds the clone with on the source chain.
- **`bridge`** — which bridge implementation handles the route (SpokePool, CCTP, OFT, etc.). Represented in the leaf preimage as the `bridgeImpl` contract address.
- **`destinationChainId`** — the canonical chain ID where funds land.
- **`outputToken`** — what the user receives on the destination chain.

Source chain is not a dimension. It's implicit in _which_ policy proxy is being read: each chain has its own proxy carrying its own immutable root (via its current implementation), so a leaf committed to chain A's root cannot be proven against chain B's root. The chain context is enforced by per-chain deployment, not by anything in the leaf.

Realistic policies are sparse (CCTP only handles USDC, OFT only specific tokens, etc.). Typical sizes:

| Policy scope                           | Leaf count | Proof depth |
| -------------------------------------- | ---------- | ----------- |
| Per `(dstChain, outputToken)`          | ~8         | ~3          |
| Per `dstChain`, all outputs            | ~32        | ~5          |
| Wide canonical (all dst, all outputs)  | ~90–150    | ~7          |
| Per-integrator wide (5 dst, 4 outputs) | ~100–150   | ~7          |

Trees are small enough that per-execute proof cost is negligible and the multisig review surface is something signing tools can render as a short table.

Adding a new input token, destination, output token, or bridge requires re-rooting the policy on each chain it applies to. Adding a new source chain is a fresh policy deployment on that chain — no impact on existing chains' policies.

---

## Cross-chain address consistency

For a clone to land at the same CREATE2 address on every EVM chain, its initCode must be identical across chains. That requires:

- **Factory at the same address everywhere.** `CounterfactualDepositFactory` and the dispatcher have no chain-specific construction state and are deployed through the deterministic-deployment proxy (`0x4e59b44847b379578588920cA78FbF26c0B4956C`) with identical initCode.
- **Identical immutable args.** The clone's appended immutable arg is a single 32-byte `argsHash`. The five underlying fields (`outputToken`, `destinationChainId`, `recipient`, `userAddress`, `routePolicyAddress`) are identical across chains by definition, so `argsHash` is identical too. `routePolicyAddress` must also be identical, which means the policy itself must land at the same address everywhere.
- **Policy proxy at the same address everywhere.** Deploy the `RoutePolicyImmutableRoot` implementation through the deterministic-deployment proxy with constructor arg `bytes32(0)` (the genesis sentinel root, identical across chains), then deploy an `ERC1967Proxy` pointing at it with init data `abi.encodeCall(RoutePolicyImmutableRoot.initialize, (deployerEOA))` (the same EOA the deploying party controls on every chain). Both go through the deterministic-deployment proxy. Ownership is transferred to the chain-local multisig as a per-chain post-deploy step — a state change that doesn't affect the proxy's address.

Once the policy proxy is deployed and transferred to the chain-local multisig, each chain rotates independently. The first rotation deploys a chain-specific implementation carrying that chain's real root and upgrades the proxy to it. The merkle tree on Ethereum commits to routes originating from Ethereum; the tree on Arbitrum commits to Arbitrum routes; and so on. **The proxy address is uniform across chains; the implementation behind it diverges per chain after genesis.** This is what makes new source chains cheap to add — deploy genesis impl + proxy on the new chain, then upgrade to a chain-specific impl, no impact on existing chains.

Tron remains a carveout. Its TVM uses a different CREATE2 prefix, so Tron clones derive to different addresses than EVM clones for the same identity. The dispatcher itself is identical between Tron and EVM (no constructor args), so it lands at the same address on Tron as on EVM chains — but clones differ because of the CREATE2 prefix. `WithdrawImplementationTron` is a separate contract from the canonical `WithdrawImplementation`; admins on Tron-deployed clones can choose to invoke whichever applies.

---

## Deployment

Deployment must follow a fixed order because two contracts depend on each other's deterministic addresses at construction time:

1. **`WithdrawImplementation`** — deploy first, through the deterministic-deployment proxy (`0x4e59b44847b379578588920cA78FbF26c0B4956C`). No constructor args, so the same address lands on every EVM chain.
2. **`CounterfactualDeposit` (dispatcher)** — deploy through the same proxy. No constructor args; initCode is identical across chains, so it lands at the same address everywhere. No deployment-ordering dependency on `WithdrawImplementation` (admins reference the withdraw impl directly at execute time).
3. **`RoutePolicyImmutableRoot`** — two deterministic deploys: (a) the implementation contract, constructed with `bytes32(0)` as the genesis root; (b) an `ERC1967Proxy` pointing at the implementation with init data `abi.encodeCall(RoutePolicyImmutableRoot.initialize, (deployerEOA))`. Both go through the deterministic-deployment proxy. The deployer EOA must be the same address on every chain — it's baked into the proxy's init data, so any change makes the proxy land at a different address. The genesis root must be `bytes32(0)` (or some other constant) across chains so the implementation's bytecode is identical and it lands at the same address everywhere.
4. **Transfer policy ownership** — separately per chain, the deployer EOA calls `transferOwnership(chainLocalMultisig)`. This is a state change, not an initCode change, so it doesn't affect the policy's address. Until this transfer lands, the deployer EOA holds full upgrade authority on the policy — see the [RoutePolicy contract](#routepolicy-contract) section for operational mitigations.
5. **Bridge implementations** (`CounterfactualDepositSpokePool`, `CounterfactualDepositCCTP`, `CounterfactualDepositOFT`) — deploy with their chain-specific constructor args (SpokePool address, signer address, wrapped native, etc.). These intentionally land at different addresses per chain since their constructor args differ.
6. **`AdminWithdrawManager`** — deploy with `(owner, directWithdrawer, signer)`. Chain-specific.
7. **`CounterfactualDepositFactory`** / **`CounterfactualDepositFactoryTron`** — deploy through the proxy. Because the factory's only chain-dependent reference is the dispatcher (which lives at the same address everywhere), the factory's initCode is identical and it lands at the same address everywhere.
8. **First root rotation** — the multisig deploys a new implementation `new RoutePolicyImmutableRoot(initialRoot)` and calls `proxy.upgradeToAndCall(newImpl, "")` to activate the policy. Until this transaction lands the policy is unusable (root is `bytes32(0)`, no proof can verify).

The invariant to remember: anything whose constructor arg comes from a deterministic-proxy-deployed contract is itself eligible for deterministic deployment, as long as it's deployed _after_ its dependency. The ordering above is the only valid topological sort.

**Tron path.** Tron's deployment mirrors steps 1–8 with `WithdrawImplementationTron`. The dispatcher itself is identical to the EVM version (no constructor args), so it lands at the same address on Tron as on EVM; clone addresses diverge because of Tron's CREATE2 prefix.

---

## Implementation plan

Work is split into three tracks — contracts, tests, scripts — each ordered by dependency so a single PR per track (or per logical bundle within a track) is reviewable in isolation. Items within a track are listed in build order.

### Contracts

- [x] **`IRoutePolicy.sol`** — minimal interface: just `activeRoot(address clone) view returns (bytes32)`. The mechanism by which the root changes is an implementation detail, not part of the interface.
- [x] **`RoutePolicyImmutableRoot.sol`** — UUPS-upgradeable, implements `IRoutePolicy` and inherits `OwnableUpgradeable` + `UUPSUpgradeable`. The root is `bytes32 immutable` on the implementation contract — baked into runtime bytecode at construction, not stored. `initialize(address initialOwner)` is the proxy's only initializer (root is fixed by the impl's constructor). `activeRoot(address clone)` ignores its argument in V1 and returns the immutable. Owners rotate the root by deploying a new implementation and calling `upgradeToAndCall`. No timelock, no separate upgrade role (see open questions).
- [x] **`CloneArgs` struct + hashing helper** — shared `struct CloneArgs { bytes32 outputToken; uint256 destinationChainId; bytes32 recipient; address userAddress; address routePolicyAddress; }` defined in a small library (e.g. `CounterfactualCloneArgs.sol`) along with a `hash(CloneArgs)` helper. Dispatcher and factory both depend on this for hash consistency.
- [x] **`ICounterfactualImplementation.sol`** (interface update) — flat-arg signature `execute(bytes32 recipient, bytes32 outputToken, uint256 destinationChainId, address userAddress, bytes routeParams, bytes submitterData)`. `userAddress` is forwarded so impls can pin a clone-bound destination and / or gate access on the user; `routePolicyAddress` stays inside the dispatcher.
- [x] **`CounterfactualDeposit.sol`** (dispatcher) — no constructor args, no immutables. `execute(cloneArgs, implementation, routeParams, submitterData, proof)` (a) loads the clone's 32-byte `argsHash` via `Clones.fetchCloneArgs`, (b) verifies `keccak256(abi.encode(cloneArgs)) == argsHash`, (c) if `msg.sender == cloneArgs.userAddress` skips the merkle check (user escape), (d) otherwise computes the leaf as `keccak256(bytes.concat(keccak256(abi.encode(implementation, keccak256(routeParams)))))` and verifies the merkle proof against `IRoutePolicy(cloneArgs.routePolicyAddress).activeRoot(address(this))`, and (e) delegatecalls the impl forwarding `(cloneArgs.recipient, cloneArgs.outputToken, cloneArgs.destinationChainId, cloneArgs.userAddress, routeParams, submitterData)`. The dispatcher is agnostic to clone identity at the leaf level; impls that need identity binding declare so via their `routeParams` struct (see below).
- [x] **`WithdrawImplementation.sol`** — implements `ICounterfactualImplementation` with the standard 6-arg signature. Adds a contract-level `immutable admin` (typically `AdminWithdrawManager`). `execute` checks `msg.sender ∈ {admin, userAddress}`, decodes `submitterData` as `(token, amount)`, and forces the destination to `userAddress`. The user reaches the impl via the dispatcher's user escape; the immutable admin reaches it via the merkle path with a proof for the policy's withdraw leaf.
- [x] **`CloneIdentity.sol`** — shared library exposing `enforce(routeOutputToken, cloneOutputToken, routeDestChainId, cloneDestChainId)`. Identity-binding impls call this at the top of `execute`; agnostic impls don't import it.
- [x] **`CounterfactualDepositSpokePool.sol`** — identity-binding. `SpokePoolRouteParams` begins with `outputToken` and `destinationChainId` for identity binding (required because `stableExchangeRate` is a per-pair assumption), followed by input token, fee caps, exchange rate, and message. `execute` calls `CloneIdentity.enforce(...)` before any other logic.
- [x] **`CounterfactualDepositCCTP.sol`** — identity-binding. `CCTPRouteParams` includes `outputToken` and `destinationChainId` alongside the CCTP-specific fields; `execute` calls `CloneIdentity.enforce(...)` before any other logic. Signature verification continues to cover `(nonce, executionFee, signatureDeadline)` with the clone bound via EIP-712 domain separator.
- [x] **`CounterfactualDepositOFT.sol`** — identity-binding, same shape as CCTP plus the LayerZero-specific `dstEid`. Forwards `msg.value` to the OFT periphery for LayerZero fees.
- [x] **`CounterfactualDepositFactory.sol`** — `deploy` / `predictDepositAddress` take the five identity fields; internally compute `argsHash = keccak256(abi.encode(...))` and use that 32-byte hash as the clone's immutable-args blob. Update `deployAndExecute` / `deployIfNeededAndExecute` signatures accordingly. Update `DepositAddressCreated` event to emit the five fields (or just `argsHash`, since indexers can recompute).
- [x] **`CounterfactualDepositFactoryTron.sol`** — mirror the EVM factory, keep the Tron CREATE2-prefix override.
- [x] **`AdminWithdrawManager.sol`** — `SIGNED_WITHDRAW_TYPEHASH` is `SignedWithdraw(address depositAddress, address withdrawImpl, address token, uint256 amount, uint256 deadline)`; `withdrawImpl` is signed so a submitter cannot redirect to a different impl. Recipient handling differs per path: `directWithdraw(... token, recipient, amount, proof)` forwards the caller-specified recipient (trusted `directWithdrawer`); `signedWithdraw` forces the recipient to `cloneArgs.userAddress` when calling the impl (recipient is therefore omitted from the signer's typehash, so a compromised `signer` cannot redirect funds). Both paths call `clone.execute(cloneArgs, withdrawImpl, "", abi.encode(token, recipient, amount), proof)`. The dispatcher verifies the proof and the impl's `admin == manager` arm authorizes the call. Caller-supplied `cloneArgs` is required since the manager doesn't hold per-clone state.

### Tests

Existing tests in `test/evm/foundry/local/` are the starting point; each item below indicates whether it's a rewrite (existing file) or new.

- [x] **`RoutePolicyImmutableRoot.t.sol`** — owner can rotate the root via `upgradeToAndCall` to a new impl, non-owner reverts, the proxy's address survives rotations, ownership transfer works, `activeRoot(clone)` returns the rotated root, day-0 deploy with `bytes32(0)` reproduces the same proxy address.
- [ ] **`CounterfactualDeposit.t.sol`** (rewrite) — covers the dispatcher's new shape:
  - `cloneArgs` hash verification: supplying tampered `cloneArgs` (any field altered) reverts before any other check runs.
  - Per-impl identity binding semantics: a leaf authored for clone A's `(outputToken, destinationChainId)` reverts at the impl-level `CloneIdentity.enforce(...)` check when executed via clone B with different identity, even with a valid merkle proof. Verified for SpokePool, CCTP, and OFT independently since each impl performs its own check.
  - User escape: `msg.sender == cloneArgs.userAddress` bypasses the proof for any `implementation`, including when `activeRoot == bytes32(0)`. Hash verification still runs first, so a fabricated `userAddress` is rejected.
  - Non-withdraw escape still requires a valid proof against `IRoutePolicy(cloneArgs.routePolicyAddress).activeRoot(address(this))`.
  - After a root rotation (deploy new impl + `upgradeToAndCall`), the same clone can prove leaves under the new root and old proofs stop working.
  - End-to-end delegatecall: the impl receives the same `cloneArgs` the dispatcher verified.
- [ ] **`CounterfactualDepositSpokePool.t.sol`** (update) — signature now includes `clone` and `routeParamsHash`; cross-clone and cross-leaf signature reuse both revert; dynamic `executionFee` is bounded by the existing `maxFeeFixed + maxFeeBps` total-fee check; native-token path still works.
- [ ] **`CounterfactualDepositCCTP.t.sol`** (update) — local signature is required, signature reuse across clones / leaves reverts, `maxExecutionFee` bound is enforced, periphery signature is still forwarded unchanged.
- [ ] **`CounterfactualDepositOFT.t.sol`** (update) — same as CCTP plus `msg.value` is forwarded to the OFT periphery.
- [x] **`WithdrawImplementation.t.sol`** — covers the two authorized-caller paths (user-escape and manager-via-merkle), defense-in-depth rejection of random callers, native-asset transfer failure, and the forced-recipient invariant.
- [ ] **`AdminWithdrawManager.t.sol`** (update) — new EIP-712 typehash with `to`; direct-withdraw and signed-withdraw flows both round-trip through the dispatcher's escape; recipient mismatch in the signed path reverts.
- [ ] **`Tron_Counterfactual.t.sol`** (update) — mirror EVM coverage for the Tron factory + Tron withdraw impl.
- [ ] **Cross-chain address consistency test** (new, in `test/evm/foundry/local/`) — script-style test that computes `predictDepositAddress` against several mocked `block.chainid` values with identical immutable args and asserts they all match. Similar exercise for the policy proxy is covered in `RoutePolicyImmutableRoot.t.sol`.

### Scripts

All scripts live under `script/counterfactual/`. The deterministic-deployment proxy at `0x4e59b44847b379578588920cA78FbF26c0B4956C` is used for every contract that needs cross-chain address consistency.

- [ ] **`config.toml` / `CounterfactualConfig.sol`** — extend with policy-related config (deployer EOA used as `initialOwner`, initial root, chain-local multisig owner per chain, signer addresses for CCTP / OFT).
- [ ] **`DeployWithdrawImplementation.s.sol`** (update) — already deterministic; verify no constructor args change.
- [ ] **`DeployCounterfactualDeposit.s.sol`** (update) — no constructor args. Asserts the deployed dispatcher address is identical across chains.
- [ ] **`DeployRoutePolicy.s.sol`** (new) — deploys `RoutePolicyImmutableRoot(bytes32(0))` (the genesis implementation) and then an `ERC1967Proxy` pointing at it with init data `abi.encodeCall(RoutePolicyImmutableRoot.initialize, (deployerEOA))`, both via the deterministic-deployment proxy. Emits both addresses. A second `TransferRoutePolicyOwnership.s.sol` runs after, called per-chain by the deployer EOA, transferring proxy ownership to the chain-local multisig.
- [ ] **`RotateRoutePolicyRoot.s.sol`** (new) — multisig-callable script that deploys `new RoutePolicyImmutableRoot(newRoot)` and calls `proxy.upgradeToAndCall(newImpl, "")`. Takes the new root and the policy proxy address as args; usable as a Safe transaction template (or a two-step batch).
- [ ] **`DeployCounterfactualDepositSpokePool.s.sol`** (update) — no signature changes to the constructor; just rebuild against the new impl.
- [ ] **`DeployCounterfactualDepositCCTP.s.sol`** (update) — add `signer` constructor arg.
- [ ] **`DeployCounterfactualDepositOFT.s.sol`** (update) — add `signer` constructor arg.
- [ ] **`DeployCounterfactualDepositFactory.s.sol`** (update) — no constructor-arg changes; the factory's interface changed but its deploy story didn't.
- [ ] **`DeployAdminWithdrawManager.s.sol`** (update) — no constructor-arg changes (still `owner`, `directWithdrawer`, `signer`); just rebuild.
- [ ] **`DeployAllCounterfactual.s.sol`** (update) — orchestrate the full sequence: `WithdrawImplementation`, `CounterfactualDeposit`, `RoutePolicyImmutableRoot` (impl + proxy, then transfer ownership), bridge impls, `AdminWithdrawManager`, factories. The dispatcher has no constructor-arg dependency on `WithdrawImplementation`, so order between them is flexible.
- [ ] **`CheckCounterfactualDeployments.s.sol`** (update) — verify the new five-field clone-args layout decodes correctly, that `IRoutePolicy.activeRoot(clone)` returns the expected root, and that all cross-chain addresses (dispatcher, policy proxy, withdraw impl, factory) are identical to a reference chain.
- [ ] **`tron/`** counterparts — mirror the relevant updates for the Tron deployment path (Tron factory, Tron withdraw impl). The dispatcher itself is the same on Tron as EVM.

## Open questions

**1. Owner compromise / blast radius.** Because the root is immutable on the impl, root rotation _is_ an upgrade — `onlyOwner`-gated `upgradeToAndCall`. The owner can therefore (a) rotate to any chosen root by deploying a new impl carrying it, (b) deploy a malicious impl with arbitrary `activeRoot` logic, or (c) leave the policy stuck on a zero-root impl to brick it. A compromised owner can authorize draining-style routes (up to the leaf's fee caps), approve degraded fee caps, or push an implementation that returns whatever root it wants. The user escape protects fund recovery in all cases, but the policy itself can be made unusable. Mitigations to consider: a timelock between propose and activate on `upgradeToAndCall`, a separate `upgrader` role distinct from the day-to-day owner, and/or an emergency-only path that can shrink the route set without delay while expansions go through the timelock.

**2. Signature replay within the deadline (SpokePool + AdminWithdrawManager only).** CCTP and OFT bind their local sigs to `nonce` (which the periphery enforces as single-use), so once the periphery consumes the nonce the local sig is also unusable — replay closed for free. SpokePool's `ExecuteDeposit` and AdminWithdrawManager's `SignedWithdraw` don't have a nonce-like field; both signatures remain valid against the same clone until their deadline, so if the clone is refunded with at least the signed `amount` during that window an executor can replay the signature and drain it again. The `SignedWithdraw` blast radius is bounded: replay still routes to `cloneArgs.userAddress`, not to an attacker. The user receives their own money again. Options for replay protection itself:

- _Operational only (current)_: rely on short deadlines and signer-side bookkeeping. Zero gas overhead, zero contract change. Cost: any leaked or buffered signature is replay-exploitable within its deadline; correctness depends entirely on the signer's discipline.
- _Monotonic nonce_: add `mapping(address clone => uint256) nonces` in SpokePool and the manager; include `nonce` in the typehash; require equality and increment on use. Forces ordered consumption — if the signer issues two quotes, the executor must use them in order. Bad fit for the "signer broadcasts, permissionless executors pick up" model.
- _One-time signature marks (recommended)_: `mapping(bytes32 sigHash => bool used)` checked and set after `ECDSA.recover`. Allows out-of-order consumption, matches the broadcast-and-pick-up model. ~1 SSTORE per execute. For SpokePool, the mapping can live in the clone's storage (the impl is delegatecalled). For `AdminWithdrawManager`, a regular mapping in normal storage.
