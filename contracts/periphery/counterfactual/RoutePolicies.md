# Route Policies

A lighter architecture for counterfactual addresses that separates _what an address is_ from _what routes it can execute_, and lets entire groups of addresses upgrade together on a chain with a single transaction.

## What is a policy?

A policy is a deployed `RoutePolicy` contract instance. Each one holds:

- A single 32-byte `activeRoot` — the merkle root of a tree enumerating every route the policy authorizes.
- An owner address (typically a multisig) with authority to call `approve(newRoot)` and replace the active root.

The policy's content — the routes it makes available — is committed off-chain in the merkle tree. The contract's on-chain state is just the root and the owner. A policy is the unit of governance: one owner runs it, one `approve` call upgrades it, one address identifies it.

Clones reference a specific policy via their `routePolicyAddress` immutable arg. Every clone pointing at the same `RoutePolicy` shares the same set of authorized routes and upgrades together as a single action. A clone is bound to one policy for life; switching policies requires generating a new address.

Multiple policies can coexist on the same chain. The typical deployment looks like:

- **Default policy** — owned by the Across multisig. Holds the canonical set of routes (supported chains, tokens, bridges, fee caps). Most users use this.
- **Per-integrator policies** — an integrator or institutional partner can deploy their own `RoutePolicy` with their own bridge whitelist, fee caps, and supported destinations. Owned by the integrator's multisig. Their users' clones reference their policy.
- **Experimental policy** — a beta route set for early adopters to opt into. Lets new bridges or chains ship with limited blast radius before the default policy adopts them.

Each policy has its own lifecycle. Across upgrades the default policy when the protocol adds new chains or fixes bridge bugs; integrators upgrade their policies independently, on their own schedule.

## The split

Pull user identity out of the merkle tree entirely and store it as raw immutable args on the clone. Move all route data into a `RoutePolicy` contract (see [What is a policy?](#what-is-a-policy)).

**Clone immutable args (~150 bytes):**

```
outputToken         (bytes32)
destinationChainId  (uint256)
recipient           (bytes32)
withdrawUser        (address)
routePolicyAddress  (address)
```

All five values participate in CREATE2 address derivation. Same identity + same policy → same address forever. The impl reads them directly via `Clones.fetchCloneArgs`; they're tamper-proof and need no signature verification.

## What the merkle tree commits to

A `RoutePolicy` deployed on a given chain commits only to routes _originating from that chain_. Source chain is implicit in which copy of the policy is being read — the per-chain `activeRoot` storage slot enforces that automatically. Each leaf in the tree therefore represents one route on a **4-dimensional** cross-product `inputToken × bridge × dstChain × outputToken`, and carries that route's full configuration on top of the indexing dimensions: per-bridge fields (e.g. `stableExchangeRate` for SpokePool, `mintRecipient` / `minFinalityThreshold` for CCTP, `destinationHandler` and LZ gas limits for OFT), plus fee bounds (`maxFeeFixed`, `maxFeeBps`, `maxExecutionFeeBps`). The bridge dimension lives in the leaf preimage directly (via the impl address); the remaining three plus all per-route configuration sit inside the params struct hashed into the leaf:

```
leaf = keccak256(bytes.concat(keccak256(abi.encode(
    bridgeImpl,
    keccak256(abi.encode(leafParams))
))))
```

Per-bridge leaf params (illustrative):

```solidity
struct SpokePoolLeafParams {
  uint256 destinationChainId;
  bytes32 inputToken;
  bytes32 outputToken;
  uint256 stableExchangeRate;
  uint256 maxFeeFixed;
  uint256 maxFeeBps;
}

struct CCTPLeafParams {
  uint256 destinationChainId; // canonical, checked against clone
  uint32 destinationDomain; // CCTP-native, used for the bridge call
  bytes32 mintRecipient; // DstPeriphery handler on destination
  bytes32 burnToken; // == inputToken
  bytes32 finalToken; // == outputToken
  uint256 cctpMaxFeeBps;
  uint32 minFinalityThreshold;
  uint256 maxExecutionFeeBps;
}

struct OFTLeafParams {
  uint256 destinationChainId;
  uint32 dstEid;
  bytes32 destinationHandler;
  bytes32 token; // == inputToken
  bytes32 finalToken; // == outputToken
  uint256 maxOftFeeBps;
  uint256 maxExecutionFeeBps;
  // lz gas limits, etc.
}
```

What lives in submitter data and is attested by the signer's EIP-712 signature at execute time: amounts, execution fee, deadlines, exclusivity. The signer signs over `paramsHash = keccak256(leafParams)`, so the signature is bound to a specific leaf.

At execute time the impl additionally checks the leaf's `outputToken` and `destinationChainId` against the clone's immutable values. This prevents an executor from proving leaf A (with destination X, output USDC) for a clone whose immutable identity says destination Y, output USDT — even though both leaves might exist in the same policy.

## Cross-product and tree size

Each chain's policy tree enumerates a **4-dimensional** cross-product: `inputToken × bridge × dstChain × outputToken`. Realistic policies are sparse — CCTP only handles USDC, OFT only specific OFT tokens, stable-to-stable only across the supported stablecoin allowlist, etc. — so the actual leaf count is well below the dense cross-product.

Estimates for typical per-chain policy sizes:

- **Per-destination policy** (one `(dstChain, outputToken)`): `~4 inputTokens × ~2 bridges = ~8 leaves` after filtering. Proof depth ~3.
- **Per-destination, multi-output policy** (one `dstChain`, all outputs): `~4 × 2 × 1 × 4 = ~32 leaves`. Proof depth ~5.
- **Wide canonical policy** (all destinations, all outputs): `~4 × 3 × 5 × 4 ≈ 240` theoretical, ~90–150 after sparsity filtering. Proof depth ~7, ~2.5k gas per execute.
- **Per-integrator wide policy** (5 destinations, 4 outputs): similar to wide canonical — ~100–150 leaves.

Trees are small enough that per-execute proof cost is negligible and the multisig review surface is something the SDK / signing tools can render as a short table. Adding a new input token, destination, output token, or bridge requires re-rooting the policy on each chain it applies to. Adding a new source chain is a fresh deployment on that chain — no impact on existing chains' policies.

## Architecture summary

```
Clone (EIP-1167 proxy, ~195 bytes total)
  immutable args: outputToken, destinationChainId, recipient,
                  withdrawUser, routePolicyAddress
       │
       └── delegatecalls → Dispatcher (CounterfactualDeposit)
                             - reads clone immutables
                             - reads routePolicy.activeRoot()
                             - verifies merkle proof of the leaf
                             - delegatecalls Implementation

Implementation
  - checks leaf's destinationChainId / outputToken == clone immutables
  - verifies signer EIP-712 attesting to amounts / deadlines / fees
  - constructs the bridge call (clone.recipient as recipient,
    clone.outputToken as finalToken, leaf's inputToken, etc.)
  - calls the bridge

RoutePolicy contract (one or many, e.g. one per integrator)
  - owner:      Across or integrator multisig
  - activeRoot: merkle root over (inputToken × bridge × dstChain ×
                                  outputToken) route leaves for the
                                  chain this policy is deployed on
  - approve(newRoot): replaces activeRoot
```

## Cross-chain address consistency

A `RoutePolicy` is deployed through the deterministic-deployment proxy (`0x4e59b44847b379578588920cA78FbF26c0B4956C`, available on every EVM chain) with identical initCode on every chain, so a given policy lives at the same address everywhere. Ownership is set to a global placeholder at deploy time and transferred to each chain's local multisig as a post-deploy step — the contract address stays identical even though governance is chain-local.

Because the policy address is identical across chains and the other clone immutable args (`outputToken`, `destinationChainId`, `recipient`, `withdrawUser`) are user input, a clone with a given identity referencing a given policy lands at the **same CREATE2 address on every supported EVM chain**. Users can fund the address from any source chain.

Each chain's deployment of a policy has **its own `activeRoot`** in storage. The merkle tree on Ethereum commits to routes originating from Ethereum; the tree on Arbitrum commits to routes originating from Arbitrum; and so on. The root content is intentionally chain-specific — it captures what bridges and destinations are reachable from that source chain. The contract _address_ is uniform across chains; the contract _state_ is per-chain.

This is what makes new source chains cheap to add: deploy the policy on the new chain (same address via deterministic deployment), have the multisig approve a fresh root for that chain. Existing chains are untouched — no coordinated multi-chain upgrade required, no rebuild of every existing tree to add leaves for the new source.

## What this enables

- **Per-chain upgrades cover all clones at once.** One `approve(newRoot)` call on a chain upgrades every clone using that policy on that chain. No per-clone trees, no per-clone execute transactions for upgrades.
- **Adding a new source chain is independent.** Deploy the policy on the new chain and approve its root. Existing chains' policies don't change — no coordinated multi-chain upgrade required.
- **Independent policy lifecycles.** Different integrators ship route updates at their own pace.
- **Cheap clone deployment.** ~150 bytes of immutable args per clone, ~25k extra gas per deploy. No tree construction at deploy time.
- **Hash-only address derivation.** The SDK predicts the address by encoding the five immutable values; no policy-tree lookup required.
- **No clone inventory to maintain.** A `RoutePolicy` doesn't need to enumerate which clones use it.

## Tradeoffs

- **Multisig blast radius is concentrated per policy.** One approval on a policy affects every clone using it. The user-side defense is still the withdraw escape; route-policy contracts emit `Approved` events so users / integrators can audit pending changes.
- **Adding a new input token, destination, output, or bridge requires re-rooting the policy on each chain it applies to.** Routes are fully enumerated in the leaves, so any expansion of the per-chain cross-product is a root-update operation. Per-chain trees are small (typically <150 leaves even for wide policies), so the per-chain rebuild and review are tractable.
- **Policy choice is bound into the address.** Switching a clone from policy A to policy B requires regenerating the address.
- **No per-clone customization within a policy.** All clones in the same policy share the same routes and fee caps. Institutional users wanting bespoke bounds get their own dedicated policy (and address space).
