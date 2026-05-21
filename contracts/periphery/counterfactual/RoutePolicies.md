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

1. **Persistent, evolvable addresses.** An address is keyed solely to `(outputToken, destinationChainId, recipient, withdrawUser, routePolicyAddress)` and never needs to change. The routes it can execute can evolve without regenerating the address.
2. **Same address on every EVM chain** for a given identity + policy.
3. **Global upgrade per chain per policy.** One `updateRoot(newRoot)` transaction per chain upgrades every clone using that policy on that chain. No per-clone upgrade transaction.
4. **Independent integrator lifecycles.** Different policies are owned and upgraded independently of each other.
5. **Dynamic execution fees.** The executor supplies `executionFee` at execute time; a signer's EIP-712 signature authorizes it. Applies uniformly to **SpokePool, CCTP, and OFT** implementations.
6. **Bounded trust.** The policy owner is a meaningful authority but cannot redirect destination, output token, or recipient (clone immutables guard those). Fee bounds are committed in the merkle tree. The user retains a structurally-guaranteed withdraw escape.

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
│     withdrawUser, routePolicyAddress                         │
│   ))                                                         │
└──────────────────────────────────────────────────────────────┘
       │
       │ delegatecall (via EIP-1167) — caller supplies the 5 args in calldata
       ▼
┌──────────────────────────────────────────────────────────────┐                ┌──────────────────────────────────────────┐
│ CounterfactualDeposit (dispatcher, no per-clone state)       │  staticcall    │ RoutePolicy (one or many, per integrator)│
│   - verifies keccak256(args) == clone.argsHash               │ ─────────────► │   - owner: Across or integrator multisig │
│   - withdraw escape if impl == WITHDRAW_IMPL                 │   activeRoot() │   - activeRoot: merkle root over the     │
│     and msg.sender == args.withdrawUser                      │ ◄───────────── │     chain's 4-dim route-leaf tree        │
│   - else: verifies merkle proof against policy root, then    │     bytes32    │   - updateRoot(newRoot): replaces root   │
│     delegatecalls impl with verified args                    │                │                                          │
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

A policy is a deployed `RoutePolicy` contract instance. Each one holds an `activeRoot` (the merkle root of a tree enumerating every route the policy authorizes on this chain) and an `owner` (typically a multisig) with authority to replace the root.

The policy's content lives off-chain in the merkle tree; the on-chain state is just the root and the owner. A policy is the unit of governance: one owner runs it, one approval upgrades it, one address identifies it.

Clones reference a specific policy via their `routePolicyAddress` immutable arg. Every clone pointing at the same `RoutePolicy` shares the same authorized routes and upgrades together. A clone is bound to one policy for life — switching policies requires generating a new address (different `routePolicyAddress` → different CREATE2).

Multiple policies can coexist on the same chain. As one example deployment shape:

- **Default policy** — owned by the Across multisig. Holds the canonical set of routes.
- **Per-integrator policies** — an integrator or institutional partner deploys their own `RoutePolicy` with their own bridge whitelist, fee caps, and supported destinations.
- **Experimental policy** — a beta route set for early adopters to opt into.

The contracts impose no constraints on how many policies exist or who runs them; the above is illustrative.

---

## Clone immutable args

Each clone's bytecode appends a single 32-byte immutable argument after the EIP-1167 proxy bytecode:

```
argsHash = keccak256(abi.encode(
  outputToken, destinationChainId, recipient, withdrawUser, routePolicyAddress
))
```

The five underlying fields are:

| Field                | Type      | Description                                                                        |
| -------------------- | --------- | ---------------------------------------------------------------------------------- |
| `outputToken`        | `bytes32` | Token received on the destination chain. `bytes32` to support non-EVM tokens.      |
| `destinationChainId` | `uint256` | Destination chain ID (or a canonical Across-assigned ID for non-EVM destinations). |
| `recipient`          | `bytes32` | Destination-chain address that receives `outputToken`.                             |
| `withdrawUser`       | `address` | EVM address authorized to invoke the structural withdraw escape.                   |
| `routePolicyAddress` | `address` | The `RoutePolicy` that authorizes which routes this clone can execute.             |

The caller passes all five values in calldata at execute time; the dispatcher recomputes `keccak256(abi.encode(args))`, asserts it equals the clone's stored `argsHash`, and then forwards the now-verified args into the bridge implementation. Tamper-proofness comes from the hash check, not from a signature — once the hash matches, the args are as authoritative as if they were stored in clone bytecode directly.

**Why hash-of-args rather than storing the five fields directly.** Storing only the hash shrinks the appended args from ~160 bytes to 32 bytes, saving ~25k gas per clone deployment. The trade is roughly ~2k extra calldata gas per execute (passing the five fields in) plus one keccak256, which is a good deal for one-shot deposit clones (the dominant usage pattern) and only mildly worse for clones that get executed many times.

All five values still participate in CREATE2 address derivation — they're committed via the hash that appears in the clone's initcode, so two different identities produce two different clone addresses.

---

## RoutePolicy contract

A minimal `Ownable` contract with one storage slot for the active merkle root and one external function to replace it.

The constructor takes an `initialOwner` and an `initialRoot`. To make the contract land at the same address on every chain (cross-chain consistency, see below), both values must be identical across chains at deploy time. `initialOwner` is a **deployer EOA** controlled by the party deploying the policy (Across, or an integrator deploying their own policy); ownership is transferred to the chain-local multisig as a post-deploy step. Chain-local multisigs are typically not at the same address across chains, which is why a deployer EOA — held by a single party and trivially identical across chains — is used as the bootstrap owner. `initialRoot` is `bytes32(0)` (the policy is unusable until a real root is approved).

The deployer EOA holds full owner authority on the policy during the window between deployment and ownership transfer. Operationally this is mitigated by (a) using a hardware-wallet-backed key, (b) deploying and transferring ownership in the same campaign so the window is short, and (c) destroying / retiring the key after the deployment campaign — the key has no purpose after every policy on every chain has been transferred to its chain-local multisig.

The contract emits a `RootUpdated(bytes32 newRoot)` event on every successful root update. Off-chain indexers use this to detect upgrades.

Intentionally **not** included in V1 of `RoutePolicy`:

- No timelock between approval and activation (timelock is still flagged in [open questions](#open-questions) as the mitigation for owner compromise).
- No multi-root grandfathering.
- No per-leaf governance.
- No upgrade mechanism for the policy contract itself — a code-level bug would require deploying a new policy at a new address and re-rooting clones. Keeping the contract minimal (one storage slot + `Ownable`) is the mitigation; UUPS proxying would add an upgrade authority and per-execute overhead that's not worth the trade-off here.

---

## CounterfactualDeposit (dispatcher)

The dispatcher is the EIP-1167 target every clone delegatecalls into. It has no per-clone or per-call storage. It carries one immutable: the canonical `WithdrawImplementation` address, set at deploy time.

On `execute(cloneArgs, implementation, leafParams, submitterData, proof)`:

1. **Verify clone-args hash.** Fetch the clone's 32-byte immutable `argsHash`, recompute `keccak256(abi.encode(cloneArgs))`, and revert if they don't match. After this step, `cloneArgs` is as authoritative as if it had been stored directly in clone bytecode.
2. **Structural withdraw escape.** If `implementation` is the canonical `WithdrawImplementation` **and** `msg.sender == cloneArgs.withdrawUser`, skip the merkle proof entirely and delegatecall the impl. This guarantees withdraw works regardless of policy state — even if the policy contract is broken, missing, or its root is `bytes32(0)`.
3. **Merkle proof.** Reconstruct the leaf as `keccak256(bytes.concat(keccak256(abi.encode(implementation, cloneArgs.outputToken, cloneArgs.destinationChainId, keccak256(leafParams)))))` (double-hashed per the OZ standard), fetch `RoutePolicy.activeRoot()` on `cloneArgs.routePolicyAddress`, and verify the proof. Revert if it doesn't verify. Binding the clone identity into the leaf preimage makes the leaf provable only against the clone it was authored for — no separate identity check is needed.
4. **Delegatecall the implementation** with `(cloneArgs, leafParams, submitterData)`.

Step 1 is what makes step 3's binding meaningful — without the hash verification, an attacker could supply a fabricated `cloneArgs` and pick any leaf they liked.

---

## CounterfactualDepositFactory

Deploys clones via CREATE2. The user-facing API accepts the five identity fields; internally the factory computes `keccak256(abi.encode(...fields))` and uses that 32-byte hash as the clone's immutable-args blob. Exposes `deploy`, `predict`, and combined deploy-and-execute entrypoints — `predictDepositAddress` takes the same five fields and returns the deterministic address.

`CounterfactualDepositFactoryTron` mirrors the same interface but uses the Tron-specific CREATE2 prefix. Tron clones derive to different addresses than EVM clones for the same identity — same as the original counterfactual contracts.

---

## Bridge implementations

The interface every bridge impl implements is `execute(CloneArgs calldata cloneArgs, bytes calldata params, bytes calldata submitterData)`. This is a breaking change vs. the original two-argument interface — the dispatcher now forwards the verified `cloneArgs` into the impl, so the impl no longer needs to read clone bytecode itself. Because the dispatcher verifies `cloneArgs` against the clone's immutable hash _before_ delegatecalling, impls can treat `cloneArgs` as fully authoritative.

Four conventions apply across all bridge impls:

- **Leaf-params layout.** Each `*LeafParams` struct contains only bridge-specific fields (bridge-native destination encoding, fee caps, bridge config). `destinationChainId` and `outputToken` are not duplicated here — they're bound into the leaf preimage by the dispatcher via `cloneArgs`, so the impl reads them from the dispatcher-verified `cloneArgs` at execute time. **This is a breaking change to the existing structs** — `recipient`, `outputToken`, and `destinationChainId` no longer appear in any leaf params struct. SDK encoders, indexers, and off-chain leaf builders must be updated in lockstep.
- **Reads `cloneArgs` for user identity.** Recipients, output tokens, destination chain, and withdraw authority come from the dispatcher-verified `cloneArgs`, never from caller-supplied leaf params or submitter data. The bridge call's `recipient` field is `cloneArgs.recipient`; the `finalToken` field is `cloneArgs.outputToken`.
- **Dynamic `executionFee` authorized by a local signer, hard-capped per leaf.** Every bridge impl (SpokePool, CCTP, OFT) carries its own `signer` immutable and validates an EIP-712 signature at execute time over a runtime `executionFee` (plus deadline and recipient). The fee is supplied in `submitterData`, not committed in the leaf, so it can move with market conditions. Every leaf carries a fixed-amount `maxExecutionFee` field that hard-bounds the `executionFee` the signer can authorize for that route — this is what makes signer compromise non-catastrophic, since a malicious signer cannot extract more than the per-leaf cap that the policy owner committed via the merkle root. For SpokePool the existing `maxFeeFixed + maxFeeBps` total-fee check is preserved on top of this. For CCTP and OFT, local signature validation is **new** — those impls had no local signer in the original contracts and gain one as part of this design. For SpokePool the existing local signer is extended to cover the dynamic fee.
- **Signer EIP-712 binds to the clone and the leaf.** Every signer signature includes `address(this)` (the clone) and `paramsHash = keccak256(leafParams)` in its EIP-712 message. This prevents signature reuse across clones (with the same destination identity, different recipients) and across leaves (different routes within the same policy).

### SpokePool

Already had a local signer in the original contracts. This design adds:

- **Dynamic `executionFee`** — moved from leaf params into submitter data. The signer's EIP-712 message now includes `executionFee` so it cannot be inflated by the executor.
- **`paramsHash` in the signer typehash** — needed because a policy now contains multiple SpokePool leaves (different routes); signatures must not be reusable across leaves.
- **`clone` in the signer typehash** — prevents signature reuse across clones with the same destination identity.
- **New leaf-params field `maxExecutionFee`** — fixed-amount cap on the runtime `executionFee` for this route. The existing `maxFeeFixed + maxFeeBps × inputAmount` check on `relayerFee + executionFee` is preserved on top of this; together they bound both the total fee and the executionFee portion specifically.

### CCTP

In the original contracts CCTP had **no local signature validation** — it forwarded a periphery-issued quote signature unchanged. This design **adds local EIP-712 signature validation** whose sole job is to authorize the runtime `executionFee`:

- New `signer` constructor immutable.
- New typehash: `ExecuteCCTP(address clone, bytes32 paramsHash, uint256 amount, uint256 executionFee, uint32 signatureDeadline)`.
- New submitter-data fields: `executionFee`, `executionFeeRecipient`, `signatureDeadline`, `counterfactualSignature` (local signer) alongside the existing `peripherySignature` (forwarded periphery quote).
- New leaf-params field: `maxExecutionFee`, a fixed-amount cap that hard-bounds the runtime `executionFee` for this route. The signer can choose any value `≤ maxExecutionFee`; values above revert.

The CCTP periphery's existing quote signature is still required and forwarded unchanged. Two signatures are checked per execute: the periphery signature (route + amount) and the new local signature (runtime fee).

### OFT

Same pattern as CCTP — **adds local EIP-712 signature validation** that didn't previously exist on this impl, along with the EIP-712 typehash, submitter-data fields, and `maxExecutionFee` leaf-params field (fixed-amount cap on the runtime `executionFee`). The OFT periphery's existing quote signature continues to be required and forwarded unchanged.

`msg.value` is still forwarded to the OFT periphery to cover LayerZero native messaging fees.

---

## WithdrawImplementation

Invoked via the dispatcher's structural withdraw escape. Receives `(token, to, amount)` as submitter data; transfers the specified token (or native ETH) to `to`. Does not require a merkle proof and does not need to be referenced in any policy's tree.

The dispatcher pre-checks `msg.sender == clone.withdrawUser` before delegatecalling, so the impl can trust the caller.

`WithdrawImplementation` is deployed deterministically with no constructor args — same address on every EVM chain — and the dispatcher's `WITHDRAW_IMPL` immutable references it.

`AdminWithdrawManager` also changes alongside `WithdrawImplementation`. To use it, set `clone.withdrawUser = adminWithdrawManagerAddress` at clone-deploy time. Both manager paths drop their `params` and `proof` arguments since the dispatcher's structural escape bypasses the merkle check. The signed path additionally moves the recipient (`to`) into the signer's EIP-712 typehash — i.e. `SignedWithdraw(address depositAddress, address token, address to, uint256 amount, uint256 deadline)` — so the manager no longer needs an on-chain `user` field to know where to send funds. The direct-withdraw path continues to let the trusted operator choose `to` freely.

---

## Leaf format & off-chain tree construction

Each leaf is computed as `keccak256(bytes.concat(keccak256(abi.encode(bridgeImpl, keccak256(leafParams)))))`. The outer `keccak256(bytes.concat(...))` provides the OZ-standard double-hash (preventing leaf/internal-node ambiguity in the merkle proof); the inner `keccak256(abi.encode(bridgeImpl, keccak256(leafParams)))` commits to the bridge impl address alongside the params hash. `leafParams` is itself pre-hashed because it's a variable-length bytes blob — packing it through abi.encode as-is would still work but yields a longer preimage for no benefit. `bridgeImpl` is chain-specific (different per-chain immutables → different addresses), so each chain's tree naturally includes only that chain's impls.

`block.chainid` is **not** in the leaf preimage. Per-chain `RoutePolicy.activeRoot` storage enforces chain-specificity automatically — a leaf committed to chain A's root cannot be proven against chain B's root because the roots are different values.

Each chain's policy tree enumerates a **4-dimensional cross-product**: `inputToken × bridge × destinationChainId × outputToken`. The dimensions are:

- **`inputToken`** — the token the user funds the clone with on the source chain.
- **`bridge`** — which bridge implementation handles the route (SpokePool, CCTP, OFT, etc.). Represented in the leaf preimage as the `bridgeImpl` contract address.
- **`destinationChainId`** — the canonical chain ID where funds land.
- **`outputToken`** — what the user receives on the destination chain.

Source chain is not a dimension. It's implicit in _which_ `RoutePolicy` deployment is being read: each chain has its own per-chain `activeRoot` storage on its local copy of the policy contract, so a leaf committed to chain A's root cannot be proven against chain B's root. The chain context is enforced by the storage layout, not by anything in the leaf.

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
- **Identical immutable args.** The clone's appended immutable arg is a single 32-byte `argsHash`. The five underlying fields (`outputToken`, `destinationChainId`, `recipient`, `withdrawUser`, `routePolicyAddress`) are identical across chains by definition, so `argsHash` is identical too. `routePolicyAddress` must also be identical, which means the policy itself must land at the same address everywhere.
- **`RoutePolicy` at the same address everywhere.** Deploy through the deterministic-deployment proxy with constructor args that are identical across chains: `initialOwner = deployerEOA` (the same EOA the deploying party controls on every chain) and `initialRoot = bytes32(0)`. Ownership is transferred to the chain-local multisig as a per-chain post-deploy step. The transfer is a state change, not an initCode change, so it doesn't affect the policy's address.

Once the policy is deployed and transferred to the chain-local multisig, each chain's deployment has its own per-chain `activeRoot` storage. The merkle tree on Ethereum commits to routes originating from Ethereum; the tree on Arbitrum commits to Arbitrum routes; and so on. **The contract address is uniform across chains; the contract state is per-chain.** This is what makes new source chains cheap to add — deploy on the new chain, approve a fresh root for that chain, no impact on existing chains.

Tron remains a carveout. Its TVM uses a different CREATE2 prefix, so Tron clones derive to different addresses than EVM clones for the same identity. Additionally, the Tron dispatcher pins `WITHDRAW_IMPL` to `WithdrawImplementationTron` rather than the canonical EVM `WithdrawImplementation`, so the EVM and Tron dispatchers have different initCode by design — they aren't trying to land at the same address. Same shape as the original contracts.

---

## Deployment

Deployment must follow a fixed order because two contracts depend on each other's deterministic addresses at construction time:

1. **`WithdrawImplementation`** — deploy first, through the deterministic-deployment proxy (`0x4e59b44847b379578588920cA78FbF26c0B4956C`). No constructor args, so the same address lands on every EVM chain.
2. **`CounterfactualDeposit` (dispatcher)** — deploy next, through the same proxy, passing the `WithdrawImplementation` address from step 1 as the `WITHDRAW_IMPL` constructor immutable. Because that address is identical across chains, the dispatcher's initCode is identical across chains, so the dispatcher lands at the same address everywhere.
3. **`RoutePolicy`** — deploy through the proxy with `(deployerEOA, bytes32(0))` as constructor args. The deployer EOA is held by the deploying party (Across or an integrator) and must be the same address on every chain. Both constructor values must be identical across chains for the policy to land at the same address everywhere.
4. **Transfer `RoutePolicy` ownership** — separately per chain, the deployer EOA calls `transferOwnership(chainLocalMultisig)`. This is a state change, not an initCode change, so it doesn't affect the policy's address. Until this transfer lands, the deployer EOA holds full owner authority on the policy — see the [RoutePolicy contract](#routepolicy-contract) section for operational mitigations.
5. **Bridge implementations** (`CounterfactualDepositSpokePool`, `CounterfactualDepositCCTP`, `CounterfactualDepositOFT`) — deploy with their chain-specific constructor args (SpokePool address, signer address, wrapped native, etc.). These intentionally land at different addresses per chain since their constructor args differ.
6. **`AdminWithdrawManager`** — deploy with `(owner, directWithdrawer, signer)`. Chain-specific.
7. **`CounterfactualDepositFactory`** / **`CounterfactualDepositFactoryTron`** — deploy through the proxy. Because the factory's only chain-dependent reference is the dispatcher (which lives at the same address everywhere), the factory's initCode is identical and it lands at the same address everywhere.
8. **First root approval** — the multisig calls `RoutePolicy.updateRoot(initialRoot)` to activate the policy. Until this transaction lands the policy is unusable (root is `bytes32(0)`, no proof can verify).

The invariant to remember: anything whose constructor arg comes from a deterministic-proxy-deployed contract is itself eligible for deterministic deployment, as long as it's deployed _after_ its dependency. The ordering above is the only valid topological sort.

**Tron path.** Tron's deployment mirrors steps 1–8 with `WithdrawImplementationTron` and a Tron-specific dispatcher; addresses diverge from the EVM path by design (different CREATE2 prefix, different `WITHDRAW_IMPL`).

---

## Implementation plan

Work is split into three tracks — contracts, tests, scripts — each ordered by dependency so a single PR per track (or per logical bundle within a track) is reviewable in isolation. Items within a track are listed in build order.

### Contracts

- [x] **`IRoutePolicy.sol`** — minimal interface: `activeRoot() view returns (bytes32)`, `updateRoot(bytes32 newRoot)`, `RootUpdated(bytes32)` event.
- [x] **`RoutePolicy.sol`** — implements `IRoutePolicy`, inherits `Ownable`. One storage slot for `activeRoot`. Constructor takes `(address initialOwner, bytes32 initialRoot)`. No timelock, no version counter (see open questions).
- [x] **`CloneArgs` struct + hashing helper** — shared `struct CloneArgs { bytes32 outputToken; uint256 destinationChainId; bytes32 recipient; address withdrawUser; address routePolicyAddress; }` defined in a small library (e.g. `CounterfactualCloneArgs.sol`) along with a `hash(CloneArgs)` helper. Dispatcher and factory both depend on this for hash consistency.
- [x] **`ICounterfactualImplementation.sol`** (interface update) — evolve `execute` to `execute(CloneArgs calldata cloneArgs, bytes calldata params, bytes calldata submitterData)`. All bridge impls update their signatures accordingly.
- [x] **`CounterfactualDeposit.sol`** (dispatcher rewrite) — adds `WITHDRAW_IMPL` constructor immutable; `execute(cloneArgs, implementation, leafParams, submitterData, proof)` (a) loads the clone's 32-byte `argsHash` via `Clones.fetchCloneArgs`, (b) verifies `keccak256(abi.encode(cloneArgs)) == argsHash`, (c) runs the structural withdraw escape using `cloneArgs.withdrawUser`, (d) computes the leaf as `keccak256(bytes.concat(keccak256(abi.encode(implementation, cloneArgs.outputToken, cloneArgs.destinationChainId, keccak256(leafParams)))))` (binding clone identity into the leaf preimage so the leaf can only be proven against the clone it was authored for), (e) fetches `RoutePolicy(cloneArgs.routePolicyAddress).activeRoot()` and verifies the merkle proof, and (f) delegatecalls the impl forwarding `cloneArgs`.
- [x] **`WithdrawImplementation.sol`** — drop `WithdrawParams`. New signature `execute(CloneArgs calldata cloneArgs, bytes calldata params, bytes calldata submitterData)` ignores `cloneArgs` and `params` and decodes `submitterData` as `(token, to, amount)`. Remove the `msg.sender == admin || msg.sender == user` check (now enforced by the dispatcher's escape).
- [x] **`CounterfactualDepositSpokePool.sol`** — adopt the new interface signature; extend `EXECUTE_DEPOSIT_TYPEHASH` to include `address clone` and `bytes32 paramsHash`; move `executionFee` out of `SpokePoolDepositParams` (leaf) and into `SpokePoolSubmitterData` (runtime); add a new `maxExecutionFee` field to `SpokePoolDepositParams` that hard-caps `executionFee`; drop `destinationChainId`, `outputToken`, and `recipient` from the struct (clone identity is bound into the leaf preimage via `cloneArgs`; recipient is read from `cloneArgs`).
- [x] **`CounterfactualDepositCCTP.sol`** — adopt the new interface signature; add `signer` constructor immutable, `ExecuteCCTP` EIP-712 typehash, signature verification over `(clone, paramsHash, amount, executionFee, signatureDeadline)`, new submitter-data fields, and `maxExecutionFee` leaf field (fixed-amount cap on `executionFee`). Clone identity is bound into the leaf preimage by the dispatcher — `destinationChainId` and `outputToken` are not in the params struct.
- [x] **`CounterfactualDepositOFT.sol`** — same treatment as CCTP plus `msg.value` forwarding to the OFT periphery is preserved.
- [x] **`CounterfactualDepositFactory.sol`** — `deploy` / `predictDepositAddress` take the five identity fields; internally compute `argsHash = keccak256(abi.encode(...))` and use that 32-byte hash as the clone's immutable-args blob. Update `deployAndExecute` / `deployIfNeededAndExecute` signatures accordingly. Update `DepositAddressCreated` event to emit the five fields (or just `argsHash`, since indexers can recompute).
- [x] **`CounterfactualDepositFactoryTron.sol`** — mirror the EVM factory, keep the Tron CREATE2-prefix override.
- [x] **`AdminWithdrawManager.sol`** — drop `params` and `proof` from both withdraw paths; change `SIGNED_WITHDRAW_TYPEHASH` to `SignedWithdraw(address depositAddress, address token, address to, uint256 amount, uint256 deadline)` so the signer fixes the recipient; the manager calls `clone.execute(cloneArgs, WITHDRAW_IMPL, "", abi.encode(token, to, amount), new bytes32[](0))` and lets the dispatcher's escape do the auth. Caller-supplied `cloneArgs` is required since the manager no longer holds per-clone state — it just forwards what the operator/signer provides.

### Tests

Existing tests in `test/evm/foundry/local/` are the starting point; each item below indicates whether it's a rewrite (existing file) or new.

- [ ] **`RoutePolicy.t.sol`** (new) — owner can `updateRoot`, non-owner reverts, `RootUpdated` event emitted with the new root, `activeRoot()` returns the latest root, two-step ownership transfer works.
- [ ] **`CounterfactualDeposit.t.sol`** (rewrite) — covers the dispatcher's new shape:
  - `cloneArgs` hash verification: supplying tampered `cloneArgs` (any field altered) reverts before any other check runs.
  - Leaf identity binding: a leaf authored for clone A's `(outputToken, destinationChainId)` does not verify against clone B with a different identity, even with a valid merkle proof.
  - Structural withdraw escape: `msg.sender == cloneArgs.withdrawUser` + `implementation == WITHDRAW_IMPL` bypasses the proof, including when `activeRoot == bytes32(0)`. Hash verification still runs first, so a fabricated `withdrawUser` is rejected.
  - Non-withdraw escape still requires a valid proof against `RoutePolicy(cloneArgs.routePolicyAddress).activeRoot()`.
  - After `RoutePolicy.updateRoot(newRoot)`, the same clone can prove leaves under the new root and old proofs stop working.
  - End-to-end delegatecall: the impl receives the same `cloneArgs` the dispatcher verified.
- [ ] **`CounterfactualDepositSpokePool.t.sol`** (update) — signature now includes `clone` and `paramsHash`; cross-clone and cross-leaf signature reuse both revert; dynamic `executionFee` is bounded by the new per-leaf `maxExecutionFee` cap _and_ by the existing `maxFeeFixed + maxFeeBps` total-fee check; native-token path still works.
- [ ] **`CounterfactualDepositCCTP.t.sol`** (update) — local signature is required, signature reuse across clones / leaves reverts, `maxExecutionFee` bound is enforced, periphery signature is still forwarded unchanged.
- [ ] **`CounterfactualDepositOFT.t.sol`** (update) — same as CCTP plus `msg.value` is forwarded to the OFT periphery.
- [ ] **`WithdrawImplementation.t.sol`** (slim down) — drops the admin/user-auth tests (now covered by the dispatcher tests) and keeps token / native transfer correctness.
- [ ] **`AdminWithdrawManager.t.sol`** (update) — new EIP-712 typehash with `to`; direct-withdraw and signed-withdraw flows both round-trip through the dispatcher's escape; recipient mismatch in the signed path reverts.
- [ ] **`Tron_Counterfactual.t.sol`** (update) — mirror EVM coverage for the Tron factory + Tron withdraw impl.
- [ ] **Cross-chain address consistency test** (new, in `test/evm/foundry/local/`) — script-style test that computes `predictDepositAddress` against several mocked `block.chainid` values with identical immutable args and asserts they all match. Same exercise for `RoutePolicy` (constructor args identical → same address).

### Scripts

All scripts live under `script/counterfactual/`. The deterministic-deployment proxy at `0x4e59b44847b379578588920cA78FbF26c0B4956C` is used for every contract that needs cross-chain address consistency.

- [ ] **`config.toml` / `CounterfactualConfig.sol`** — extend with policy-related config (deployer EOA used as `initialOwner`, initial root, chain-local multisig owner per chain, signer addresses for CCTP / OFT).
- [ ] **`DeployWithdrawImplementation.s.sol`** (update) — already deterministic; verify no constructor args change.
- [ ] **`DeployCounterfactualDeposit.s.sol`** (update) — pass `WITHDRAW_IMPL` constructor arg, sourced from the deterministic `WithdrawImplementation` address. Asserts the deployed dispatcher address is identical across chains.
- [ ] **`DeployRoutePolicy.s.sol`** (new) — deploys `RoutePolicy` via deterministic-deployment proxy with `(deployerEOA, bytes32(0))`; emits the deployed address. A second `TransferRoutePolicyOwnership.s.sol` runs after, called per-chain by the deployer EOA, transferring ownership to the chain-local multisig.
- [ ] **`ApproveRoutePolicyRoot.s.sol`** (new) — multisig-callable script that calls `RoutePolicy.updateRoot(newRoot)`. Takes the new root and the policy address as args; usable as a Safe transaction template.
- [ ] **`DeployCounterfactualDepositSpokePool.s.sol`** (update) — no signature changes to the constructor; just rebuild against the new impl.
- [ ] **`DeployCounterfactualDepositCCTP.s.sol`** (update) — add `signer` constructor arg.
- [ ] **`DeployCounterfactualDepositOFT.s.sol`** (update) — add `signer` constructor arg.
- [ ] **`DeployCounterfactualDepositFactory.s.sol`** (update) — no constructor-arg changes; the factory's interface changed but its deploy story didn't.
- [ ] **`DeployAdminWithdrawManager.s.sol`** (update) — no constructor-arg changes (still `owner`, `directWithdrawer`, `signer`); just rebuild.
- [ ] **`DeployAllCounterfactual.s.sol`** (update) — orchestrate the full sequence: `WithdrawImplementation` → `CounterfactualDeposit` → `RoutePolicy` (then transfer ownership) → bridge impls → `AdminWithdrawManager` → factories. Document the ordering invariant: `WithdrawImplementation` must land first so the dispatcher's `WITHDRAW_IMPL` constructor arg is known.
- [ ] **`CheckCounterfactualDeployments.s.sol`** (update) — verify the new five-field clone-args layout decodes correctly, that `RoutePolicy.activeRoot()` matches the expected root, that `WITHDRAW_IMPL` on the dispatcher matches the deployed `WithdrawImplementation`, and that all cross-chain addresses (dispatcher, policy, withdraw impl, factory) are identical to a reference chain.
- [ ] **`tron/`** counterparts — mirror the relevant updates for the Tron deployment path (Tron factory, Tron withdraw impl, Tron dispatcher with `WithdrawImplementationTron` as `WITHDRAW_IMPL`).

## Open questions

**1. Owner compromise / blast radius.** The `RoutePolicy` owner can replace `activeRoot` with any value in one transaction. A compromised owner can authorize draining-style routes (up to the leaf's fee caps), approve degraded fee caps, or set `bytes32(0)` to brick the policy. The structural withdraw escape protects user funds in all cases, but the policy itself can be made unusable. Mitigations to consider: a timelock between propose and activate, and/or an emergency-only path that can shrink the route set without delay while expansions go through the timelock.

**2. How should withdraw be structured?** The current design splits withdraw across two axes — _where the authorization lives_ (dispatcher's structural escape vs. merkle-proof through the policy) and _where the transfer logic lives_ (a separate `WithdrawImplementation` vs. inlined in the dispatcher). Today it's "structural auth + separate impl": the dispatcher special-cases the auth path (`implementation == WITHDRAW_IMPL && msg.sender == cloneArgs.withdrawUser`), then delegatecalls a one-purpose `WithdrawImplementation` that decodes `(token, to, amount)` and transfers. The impl conforms to `ICounterfactualImplementation` for uniformity, but two of its three arguments are unused and its address is pinned by the dispatcher's `WITHDRAW_IMPL` immutable — so it isn't actually swappable. Three coherent options:

- _Structural auth + separate impl (current)_: strongest user-fund guarantee — withdraw works regardless of policy state, including when `activeRoot == bytes32(0)` or the policy owner is compromised. Uniform `ICounterfactualImplementation` interface across every execute target. Cost: a second contract to deploy and verify per chain, a `WITHDRAW_IMPL` immutable on the dispatcher, a deployment ordering invariant (withdraw impl must land before the dispatcher), an `AdminWithdrawManager` special-cased code path, and a vestigial interface conformance on the impl side (`cloneArgs` and `params` are unused).
- _Structural auth + inlined into dispatcher_: keep the same fund-safety guarantee but drop the separate impl. Move the `(token, to, amount)` decode + transfer into a dispatcher method that the escape branch falls into directly. The escape becomes a function call rather than an impl dispatch. Cost: the dispatcher gains a transfer code path and a `SafeTransferERC20` dependency, and the abstraction "every execute goes through an impl" is broken — withdraw becomes a structural feature of the dispatcher rather than a pluggable implementation. Saves one contract, one immutable, one delegatecall hop, and the unused-parameter conformance.
- _Policy-committed withdraw_: drop the structural escape entirely; commit withdraw routes as ordinary leaves in the `RoutePolicy` merkle tree. Simplest dispatcher — uniform code path for every execute, no escape branch, no `WITHDRAW_IMPL` immutable, no special case in `AdminWithdrawManager`. Cost: a compromised or misconfigured policy can revoke the user's ability to withdraw, eliminating the bounded-trust property; the policy owner becomes load-bearing for fund safety, not just route safety. Note also that the current `WithdrawImplementation` is not safe to use directly as a policy leaf — `submitterData` is fully attacker-controlled, so a withdraw leaf would let any caller drain to any `to`. Going this route requires either binding `to` (and likely `token`, `amount`) into `params` so the leaf commits them, or adding auth inside the withdraw impl. Either way it's a redesign, not just a leaf addition.

**3. Signature replay within the deadline.** None of the four EIP-712 signed messages (SpokePool `ExecuteDeposit`, CCTP `ExecuteCCTP`, OFT `ExecuteOFT`, AdminWithdrawManager `SignedWithdraw`) include a nonce or one-time mark. A signature remains valid against the same clone until `signatureDeadline` / `deadline` elapses, so if the clone is refunded with at least the signed `amount` during that window an executor can replay the signature and drain it again. The replay window is bounded by the deadline and by clone balance, but there is no on-chain protection. The `SignedWithdraw` path is the most replay-prone of the four because the signature commits a fixed `(token, to, amount)` triple — a refund of the same amount allows a second drain to the same `to` with no further coordination. Options:

- _Operational only (current)_: rely on short deadlines and signer-side bookkeeping. Zero gas overhead, zero contract change. Cost: any leaked or buffered signature is replay-exploitable within its deadline; correctness depends entirely on the signer's discipline.
- _Monotonic nonce_: add `mapping(address clone => uint256) nonces` in each impl and the manager; include `nonce` in the typehash; require equality and increment on use. Forces ordered consumption — if the signer issues two quotes, the executor must use them in order. Bad fit for the "signer broadcasts, permissionless executors pick up" model.
- _One-time signature marks (recommended)_: `mapping(bytes32 sigHash => bool used)` checked and set after `ECDSA.recover`. Allows out-of-order consumption, matches the broadcast-and-pick-up model. ~1 SSTORE per execute. For CCTP/OFT/SpokePool, the mapping can live in a small shared `SignatureMarks` mixin using ERC-7201 namespaced storage (so all three impls share one slot in the clone's storage without colliding with anything else). For `AdminWithdrawManager`, a regular mapping in normal storage (the manager is not delegatecalled).
