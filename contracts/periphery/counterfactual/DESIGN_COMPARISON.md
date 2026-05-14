# Enumerated Routes vs. Registry Routes vs. Signed Routes

Comparison of three designs for representing source-side route options in a counterfactual deposit address. All three share the same chainId-in-leaf foundation (a single merkle root → same CREATE2 clone address across EVM chains); they differ in **where** route-specific data (source chain addresses, source token, bridge contract address) lives.

|                                     | **Enumerated Routes**                                                                                  | **Registry Routes**                                                                          | **Signed Routes**                                                                                   |
| ----------------------------------- | ------------------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------- |
| One-line summary                    | Every `(srcChain, inputToken, bridge)` combo enumerated in the merkle tree with raw addresses          | Tree uses IDs; a global config contract resolves IDs → addresses per chain at execute time   | Tree commits only to destination identity; signer authorizes source-side fields per call            |
| What's in the leaf                  | `(chainId, impl, params)` — params has raw `inputToken` address, fee caps, exchange rate, executionFee | `(chainId, impl, params)` — params has `inputTokenId`, fee caps, exchange rate, executionFee | `(chainId, impl, paramsLite)` — paramsLite has only `(dstChain, outputToken, recipient, maxFeeBps)` |
| Impl addresses                      | Different per chain (chain-specific immutables)                                                        | **Same on every chain** (chain-agnostic; reads registry)                                     | Different per chain                                                                                 |
| Bridge contract addresses come from | Impl immutables (frozen at deploy)                                                                     | Registry lookup at execute time                                                              | Impl immutables                                                                                     |
| Token addresses come from           | Leaf params (frozen at address gen)                                                                    | Registry lookup at execute time                                                              | Submitter data + signer-signed                                                                      |

## The three designs

### Enumerated Routes (currently implemented)

The off-chain SDK builds a tree containing one leaf per `(srcChainId, implementation, params)` tuple in the cross product `srcChains × inputTokens × bridges`. The leaf's `params` carries the full route description with raw addresses: source token, destination token, recipient, fee caps, exchange rate, execution fee. The signer's EIP-712 signature binds amounts to a specific leaf via `paramsHash`.

Example for "USDC on HyperEVM, recipient X" over 6 source chains × 4 input tokens × 2 bridges → ~30 deposit leaves + 6 withdraw leaves ≈ **36 leaves**, padded to 64.

### Registry Routes

A single `ChainConfig` contract is deployed deterministically (no constructor args, same address on every EVM chain) and holds mutable mappings:

```solidity
mapping(uint32 bridgeId => address) public bridges;   // CCTP_PERIPHERY → 0x... per chain
mapping(uint32 tokenId  => address) public tokens;    // USDC → 0x... per chain
// plus chain-specific scalars: CCTP source domain, OFT srcEid, etc.
```

Implementations (`CounterfactualDepositSpokePool/CCTP/OFT`) become **chain-agnostic** — their constructor takes only the registry address (same everywhere), no chain-specific immutables. Same bytecode → same CREATE2 address on every chain.

Leaf `params` use IDs (`burnTokenId`, `finalTokenId`, etc.) instead of raw addresses. At execute time, the impl reads `tokens[burnTokenId]` and `bridges[CCTP_PERIPHERY]` to resolve the actual addresses.

Tree size for the same example: still ~36 leaves (you still enumerate the chain × token × bridge cross-product), but each leaf is smaller and the SDK works in ID-space.

### Signed Routes

The tree commits only to destination identity — `(dstChain, outputToken, recipient)` plus chain-agnostic bounds like `maxFeeBps`. The leaf doesn't say anything about which source token. At execute time the relayer submits the chosen `inputToken` and amounts in submitter data, signed by the signer in an expanded EIP-712 payload.

Tree size for the same example: ~6 destination leaves (one per source chain × bridge type) + 6 withdraw leaves ≈ **12 leaves**, padded to 16.

## Gas estimates

Best-effort estimates. Deploy is a CREATE2 of an EIP-1167 clone with 32-byte immutable args (the merkle root); it's the same operation in all three designs. Execute varies because of proof depth, calldata, and storage reads.

These numbers are calibrated against the current local test suite (where `testExecuteViaFactory()` for SpokePool runs at ~425k gas and for CCTP at ~300k gas), plus delta calculations for the changes each design introduces. Real-world numbers will vary by L1/L2, by token (USDC `transferFrom` is slightly cheaper than DAI, etc.), and by whether the relayer has touched the relevant storage slots earlier in the same tx.

### Deploy a counterfactual

**~100k gas** in all three designs (within ~5k of each other). The clone is the same shape — EIP-1167 proxy bytecode + 32-byte merkle root — regardless of design. The bulk of the cost is:

- CREATE2 base (~32k)
- Clone bytecode deployment (~12k)
- Immutable arg storage (~5k)
- Event emission (~3k)
- Factory overhead (~10k)
- Plus `forge-test` overhead (~30k) — production deploys lower

If your CREATE2 deployer pre-warms (e.g., the deterministic deployer at `0x4e59…956C` is widely accessed), realistic production deploy is **~75–90k gas**.

### Execute a deposit

| Bridge        | Enumerated Routes | Registry Routes | Signed Routes |
| ------------- | ----------------- | --------------- | ------------- |
| **SpokePool** | ~425k             | ~432k           | ~422k         |
| **CCTP**      | ~295k             | ~302k           | ~292k         |
| **OFT**       | ~360k             | ~367k           | ~358k         |

The deltas are small relative to total cost because most of the gas is spent inside the bridge call (SpokePool/CCTP/OFT itself), not in the dispatcher or impl.

**Where the deltas come from:**

- **Registry Routes adds ~6–8k per execute.** Two cold SLOADs on the registry contract: cold account access (~2600) + cold slot for `bridges[id]` (~2100) + cold slot for `tokens[id]` (~2100) ≈ 6.8k. If the relayer hits the registry repeatedly within one tx (e.g., batching), subsequent accesses warm and drop to ~100 each.
- **Signed Routes saves ~2–3k vs Enumerated.** Smaller proof (4 vs 6 hashes ≈ -700), smaller params calldata (≈ -1500), offset by larger submitter-data calldata and bigger EIP-712 struct hash (+500–1000). Net wash to slight savings.
- **Enumerated Routes is the baseline.**

For relayers running many executes per day, Registry's per-call SLOAD overhead is the only meaningfully visible difference, and it amounts to ~0.001 USD per execute at L2 prices. Not a material driver.

## Tree size and proof depth

|                                                                                        | Enumerated Routes              | Registry Routes                         | Signed Routes                  |
| -------------------------------------------------------------------------------------- | ------------------------------ | --------------------------------------- | ------------------------------ |
| Typical leaf count (10 chains × 3 tokens × 2 bridges + withdraws)                      | ~70 (pad to 128)               | ~70 (pad to 128)                        | ~30 (pad to 32)                |
| Proof depth                                                                            | 7 hashes (224 bytes)           | 7 hashes (224 bytes)                    | 5 hashes (160 bytes)           |
| Per-leaf calldata size                                                                 | Larger (raw addresses)         | Smaller (IDs)                           | Smallest                       |
| Address regen when adding a new input token                                            | Yes                            | Yes                                     | **No** (signer just learns)    |
| Address regen when adding a new source chain                                           | Yes                            | Yes                                     | Yes                            |
| Address regen when adding a new bridge type                                            | Yes                            | Yes                                     | Yes                            |
| Address regen when a bridge contract is **upgraded** (e.g., new CCTP version)          | Yes — break all live addresses | **No** — registry update fixes everyone | Yes — break all live addresses |
| Address regen when a **token contract is migrated** (e.g., bridged USDC → native USDC) | Yes                            | **No** — registry update fixes everyone | Depends on signer service      |

The bridge-upgrade / token-migration row is where Registry Routes pulls ahead. Bridges and canonical tokens _do_ get migrated occasionally (CCTP v1 → v2, bridged USDC → native USDC, etc.), and under Enumerated and Signed Routes, all live addresses break and users have to regenerate. Registry Routes survives these transitions with a governance action.

## Trust model

| Authority held by                                     | Enumerated Routes                | Registry Routes                                           | Signed Routes                            |
| ----------------------------------------------------- | -------------------------------- | --------------------------------------------------------- | ---------------------------------------- |
| `inputToken` choice                                   | Tree (raw address)               | Tree (id) → Registry (address)                            | Signer (per call)                        |
| Bridge contract address                               | Impl immutable                   | Registry                                                  | Impl immutable                           |
| `inputAmount`                                         | Signer                           | Signer                                                    | Signer                                   |
| `outputAmount`                                        | Signer, bounded by tree fee caps | Signer, bounded by tree fee caps                          | Signer, bounded by tree `maxFeeBps` only |
| `stableExchangeRate`                                  | Tree                             | Tree                                                      | Signer (per call)                        |
| `executionFee`                                        | Tree                             | Tree                                                      | Tree-capped or signer-signed             |
| `destinationChainId` / `dstEid` / `destinationDomain` | Tree                             | Tree (id) → Registry                                      | Tree                                     |
| `outputToken` / `finalToken`                          | Tree                             | Tree (id) → Registry                                      | Tree                                     |
| `recipient` / `finalRecipient`                        | Tree                             | Tree                                                      | Tree                                     |
| Registry governance authority                         | N/A                              | **Can update bridge/token addresses for all live clones** | N/A                                      |
| Signer authority breadth                              | Narrow (amounts)                 | Narrow (amounts)                                          | Wide (route + amounts)                   |

### Who can hurt the user, and how

| Scenario                                           | Enumerated Routes                                                  | Registry Routes                                                | Signed Routes                                   |
| -------------------------------------------------- | ------------------------------------------------------------------ | -------------------------------------------------------------- | ----------------------------------------------- |
| Skim a deposit within `maxFee` cap                 | Compromised signer can, bounded                                    | Compromised signer can, bounded                                | Compromised signer can, larger bound            |
| Pick a different source token than user intended   | Cannot                                                             | Cannot (id is in leaf, registry maps to address)               | Yes (signer picks per call)                     |
| Redirect funds to a different `recipient`          | Cannot                                                             | Cannot                                                         | Cannot                                          |
| Redirect funds to a different `outputToken` on dst | Cannot                                                             | Cannot (id is in leaf)                                         | Cannot                                          |
| Wholesale redirect every live clone                | Cannot                                                             | **Yes, via malicious registry update**                         | Cannot                                          |
| Brick every live clone                             | Cannot                                                             | Yes (set bridge to 0x0 → revert)                               | Cannot                                          |
| Honest mistake in setup                            | Wrong address in SDK → user funds wrong (loud) clone, can withdraw | Wrong registry entry → execute reverts (loud), funds stay safe | Wrong signer config → bad routes get authorized |

The asymmetry: Registry Routes' worst case (malicious admin) hits _every_ live clone at once. Enumerated and Signed Routes' worst cases hit one deposit at a time.

This is the dominant security trade-off — Registry buys operational flexibility at the cost of a global trust point. Mitigated by a high-bar multisig + timelock that gives users a window to withdraw before changes take effect.

## Backend maintainability

| Concern                                                     | Enumerated Routes                                                  | Registry Routes                                     | Signed Routes                                          |
| ----------------------------------------------------------- | ------------------------------------------------------------------ | --------------------------------------------------- | ------------------------------------------------------ |
| SDK per-chain token-address registry                        | Required, must stay perfectly in sync                              | **Not required** (lives on-chain)                   | Required for signer service                            |
| SDK per-chain impl-address registry                         | Required                                                           | **Not required** (one address everywhere)           | Required                                               |
| SDK destination-identifier mapping (chainId / domain / eid) | Required in tree builder                                           | Lives in registry, SDK uses ID                      | Required in tree builder                               |
| Tree-build function complexity                              | Highest (works in addresses)                                       | Medium (works in IDs)                               | Lowest                                                 |
| Address-derivation correctness load                         | Highest (any wrong address breaks address)                         | Lower (only IDs and chainId matter)                 | Lower                                                  |
| Policy versioning                                           | Yes — every change to enumerated set is a new policy               | Yes — but address survives bridge/token migrations  | Yes — but addresses survive token additions            |
| Signer service complexity                                   | Lowest (signs amounts within tree caps)                            | Lowest                                              | Highest (signs route fields too)                       |
| Per-address DB record size                                  | (destination, policy_v, full leaf set or seed)                     | (destination, policy_v)                             | (destination, policy_v)                                |
| Adding support for a new token                              | Regenerate addresses                                               | Regenerate addresses + registry update              | Signer learns; no regen                                |
| Adding support for a new chain                              | Regenerate addresses                                               | Regenerate addresses + deploy registry on new chain | Regenerate addresses                                   |
| Operationalizing bridge upgrades                            | Communicate "your address is dead, regenerate" to every integrator | Coordinate a timelock'd registry update             | Communicate "your address is dead" to every integrator |
| New contract to operate                                     | None                                                               | **`ChainConfig` (governance, monitoring, runbook)** | None                                                   |

**For the backend specifically:** Registry Routes is the cleanest. The SDK no longer needs to maintain per-chain address registries — it just emits IDs and chainIds into the tree, and the on-chain registry resolves them. Implementation deployments become a single deterministic-deploy script that produces the same address everywhere. The operational cost is the new `ChainConfig` contract you need to govern.

## Audit surface

|                        | Enumerated Routes                                | Registry Routes                                                                                                                   | Signed Routes                                                                                                        |
| ---------------------- | ------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------- |
| Dispatcher change      | `block.chainid` in leaf preimage                 | Same                                                                                                                              | Same                                                                                                                 |
| Impl change            | SpokePool: `paramsHash` in typehash              | All impls: chain-agnostic, registry-driven lookups, ID-based params, "registry returned 0?" handling                              | SpokePool: typehash expanded with route fields. CCTP/OFT: dynamic token approval. `maxFeeFixed` denomination problem |
| New contract           | None                                             | `ChainConfig` (mappings, admin gates, mutation events)                                                                            | None                                                                                                                 |
| New attack vectors     | Multi-leaf-same-impl cross-leaf attack (handled) | Registry-admin compromise; registry-update race conditions; "registry returns 0" handling; cross-contract reentrancy via registry | Signer scope expansion; `maxFeeFixed` denomination ambiguity; signer-signed exchange-rate manipulation               |
| Contract diff (approx) | ~10 lines (current implementation)               | ~150–200 lines (new registry + chain-agnostic impl refactor)                                                                      | ~50–80 lines                                                                                                         |

## Failure modes

| Failure                                           | Enumerated Routes                                    | Registry Routes                                                                                                                     | Signed Routes                                                          |
| ------------------------------------------------- | ---------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------- |
| SDK uses wrong token address                      | Address derives differently → no funds bridged wrong | Address derives same (uses IDs only) → execute would resolve via registry → wrong address breaks `transferFrom` → revert            | Address derives differently → no funds bridged wrong                   |
| SDK uses wrong impl address                       | Address derives differently → safe                   | Impl is same address everywhere → no SDK error possible                                                                             | Same as Enumerated                                                     |
| Honest mistake in registry entry                  | N/A                                                  | Execute reverts (clone doesn't hold the wrong token, periphery rejects unknown function) → funds stay safe, withdraw recovery works | N/A                                                                    |
| **Malicious** registry update                     | N/A                                                  | All live clones executing after the change are exposed → user funds could be redirected. Timelock gives reaction window.            | N/A                                                                    |
| Signer compromise                                 | Skim within tree caps                                | Skim within tree caps                                                                                                               | Skim within tree caps + pick bad route                                 |
| Signer key rotation                               | Tree-committed routes unaffected                     | Tree-committed routes unaffected                                                                                                    | Full route authorization shifts to new key                             |
| Bridge contract migration (e.g., new CCTP)        | All live addresses break                             | **Registry update fixes everyone**                                                                                                  | All live addresses break                                               |
| Canonical token migration (e.g., new native USDC) | All live addresses break for that token              | **Registry update fixes everyone**                                                                                                  | If signer learns of migration, addresses keep working; otherwise break |

## Per-bridge considerations

### SpokePool

- **Enumerated:** Existing impl. `paramsHash` in typehash makes multi-leaf clones safe. Fee math uses committed `inputToken`.
- **Registry:** Impl reads `inputToken` from registry by ID. Same fee math; same `paramsHash` binding still needed for multi-leaf safety. `wrappedNativeToken` also comes from registry.
- **Signed:** Signer payload expands. `maxFeeFixed` becomes ambiguous (input-token-denominated, token is dynamic). `stableExchangeRate` becomes per-call.

### CCTP

- **Enumerated:** `burnToken` raw address in leaf params. SrcPeriphery quote signature binds route.
- **Registry:** `burnTokenId` in leaf params, impl resolves via registry. SrcPeriphery quote still binds the resolved address. `sourceDomain` (currently impl immutable) also comes from registry, keyed by chainId.
- **Signed:** `burnToken` moves to submitter data. SrcPeriphery quote validates it. Impl dynamically approves whatever token was submitted.

### OFT

- **Enumerated:** `token` raw address in leaf params. SrcPeriphery quote binds it.
- **Registry:** `tokenId` in leaf params, registry-resolved. `srcEid` from registry.
- **Signed:** `token` moves to submitter data. SrcPeriphery quote validates.

## Address durability summary

| User-facing scenario                                                                | Enumerated Routes                          | Registry Routes                                     | Signed Routes                            |
| ----------------------------------------------------------------------------------- | ------------------------------------------ | --------------------------------------------------- | ---------------------------------------- |
| "I funded with token A; can I fund with token B later?"                             | Only if token B was enumerated at gen time | Only if token B's ID was enumerated at gen time     | Yes (signer adds support)                |
| "Across migrates CCTP to v2 — does my address still work?"                          | No                                         | **Yes** (registry update)                           | No                                       |
| "Bridged USDC on chain X is migrating to native USDC — does my address still work?" | No                                         | **Yes** (registry update)                           | Maybe (signer learns)                    |
| "I want my address to be valid for 2+ years"                                        | Constrained by enumerated set              | Constrained by enumerated set + survives migrations | Constrained mostly by signer flexibility |
| "I want one address that accepts any future supported token"                        | No (must regen)                            | No (must regen)                                     | **Yes**                                  |

Registry Routes is the durability winner for **infrastructure changes** (bridge/token migrations). Signed Routes is the durability winner for **catalog changes** (new tokens added to support). Enumerated has the weakest durability story but the strongest "what you signed up for is what you get" guarantee.

## Side-by-side summary

| Property                          | Enumerated Routes  | Registry Routes                          | Signed Routes           |
| --------------------------------- | ------------------ | ---------------------------------------- | ----------------------- |
| Tree size                         | Largest            | Largest (same as Enumerated)             | Smallest                |
| Per-execute gas                   | Cheapest           | +6–8k                                    | Similar to Enumerated   |
| Deploy gas                        | ~100k              | ~100k                                    | ~100k                   |
| Impl deployment                   | Per-chain bytecode | **Same address everywhere**              | Per-chain bytecode      |
| SDK address-registry burden       | High               | **None**                                 | Medium (signer service) |
| Backend simplicity                | Lowest             | **Highest**                              | Medium                  |
| Survives bridge/token migration   | No                 | **Yes (governance)**                     | No                      |
| Address durability for new tokens | Low                | Low                                      | **High**                |
| Trust model                       | Tree-bound (tight) | Tree-bound + registry governance         | Signer-delegated (wide) |
| Worst-case blast radius           | One deposit        | **All live clones (via gov compromise)** | One deposit             |
| Audit delta from main             | Smallest (current) | Largest (new contract)                   | Medium                  |
| Contract LoC change               | ~10                | ~150–200                                 | ~50–80                  |

## Recommendation framework

None of these strictly dominates. The right answer depends on three product/security choices:

1. **Are bridge contract or canonical token migrations a real concern over your address lifetime?**
   - Yes, frequently → Registry Routes (you'll thank yourself when CCTP v2 ships).
   - Rarely → Enumerated or Signed (don't take on governance risk you don't need).

2. **How important is "address survives token additions"?**
   - Critical (integrators issue addresses to end users for long-term use) → Signed Routes.
   - Nice-to-have → Enumerated or Registry.

3. **What's your risk tolerance for a global governance point of failure?**
   - Comfortable with multisig + timelock as a managed risk → Registry Routes is fine.
   - Prefer no global trust point → Enumerated or Signed.

### A hybrid worth considering

Registry Routes and Signed Routes are **stackable**. You can have:

- A registry that resolves bridge contracts and `chainSpecificScalars` (cleaning up impl deployment)
- AND signer-signed source tokens (smaller trees, longer-lived addresses for new tokens)

That hybrid trades a bigger contract diff for the union of operational benefits. Probably overkill for v1, but worth noting as a future direction.

### Quick decision guide

- **Enumerated Routes:** smallest delta from main, tightest on-chain bounds. Best if you want to ship soon, accept periodic address regeneration, and have no appetite for a new governance dependency.
- **Registry Routes:** best operational story for the backend team and biggest win for surviving bridge/token migrations. Best if you can support a high-bar governance setup for `ChainConfig` and want to minimize SDK address-registry maintenance.
- **Signed Routes:** best for integrator-issued addresses that need to outlive evolving token lists. Best if your signer is already a heavily trusted, well-operated actor and you're comfortable expanding its scope.
