# Enumerated Routes v2 — Upgradeable Counterfactual Deposits

Design spec and implementation plan for evolving the current Enumerated Routes design (see [`DESIGN_COMPARISON.md`](./DESIGN_COMPARISON.md), [`README.md`](./README.md)) to support:

1. **Identity-keyed addresses** — same CREATE2 address on every EVM chain for the same `(recipient, dstChainId, outputToken)` triple, even as the underlying merkle root changes.
2. **Upgradeable merkle roots** — per-clone root can be migrated by an executor presenting a proof against an admin-approved meta merkle root.
3. **Same supported-input semantics** — input must match output (asset₁→asset₁) or be a stable when output is a stable (stable₁→stable₂). Volatile asset swaps are out of scope for v1.
4. **Refund-on-unsupported** — unsupported inputs are recovered via the existing withdraw leaf.

## Goals & Non-Goals

**Goals**

- Preserve "deposit once, accept forever" UX. Addresses never go stale even as routes are added/upgraded.
- Cross-chain address consistency keyed only on `(recipient, dstChainId, outputToken)`.
- **Dynamic `executionFee` across all three bridge implementations.** Today only SpokePool's signed payload covers execution-time amounts; CCTP and OFT carry `executionFee` as a committed leaf param. Moving it under a signer-signed payload lets the off-chain quoter price each fill against live gas costs without re-issuing the deposit address. This requires adding an in-implementation EIP-712 signature check to `CounterfactualDepositCCTP` and `CounterfactualDepositOFT` (today they delegate signature verification entirely to the SrcPeriphery).

**Non-goals**

- Volatile-asset swaps (ETH→USDC etc.). The `stableExchangeRate` fee math still assumes input/output are non-volatile relative to one another.

## How It Works

### Lifecycle of a counterfactual address

1. **Address generation (off-chain, in SDK).** The SDK builds `identityHash = keccak256(recipient, dstChainId, outputToken)` and constructs a merkle tree enumerating every `(srcChainId, inputToken, bridge)` route the user wants supported, **across every source chain**, with each leaf carrying `block.chainid` in its preimage. The root of that tree is `initialRoot`. The predicted CREATE2 address is derived from `(factory, salt = keccak256(identityHash, initialRoot), dispatcher)` — a bare EIP-1167 proxy with no immutable args. Same address on every EVM chain.

2. **Funding (counterfactual).** User sends supported tokens (or ETH) to the predicted address before any contract is deployed. Nothing exists on-chain yet at that address.

3. **Deployment + first execute.** A relayer calls `factory.deployIfNeededAndExecute(identityHash, initialRoot, executeCalldata)`. The factory CREATE2-deploys the `CounterfactualDeposit` clone at the predicted address, atomically `initialize`s it (installs `merkleRoot = initialRoot`), and forwards the call. The clone's `execute()` verifies the merkle proof against `merkleRoot` and delegatecalls the bridge-specific implementation. **Front-run protection:** a different `initialRoot` would yield a different CREATE2 address, so an attacker can't deploy a malicious clone at the predicted address.

4. **Subsequent executes.** Once deployed, callers go straight to `factory.execute(depositAddress, calldata)` (or call the clone directly). Each execute consumes the token balance sitting at the clone, so re-funding the same address starts a new deposit at the same identity.

5. **Migration (admin-driven, executor-applied).** Admin builds an off-chain meta-merkle tree where each leaf is `keccak256(cloneAddress, newRoot)`, then calls `registry.setMetaRoot(metaMerkleRoot)`. Any executor can then call `clone.migrate(newRoot, metaProof)` on any clone whose address appears in the metaRoot. The clone verifies the proof against the registry's current `metaRoot` (keying on its own `address(this)`) and updates `merkleRoot`. Future `execute` calls use the new root.

6. **Refunds for unsupported inputs.** Tokens that don't match any deposit leaf in the current operational root are recovered through the `WithdrawImplementation` leaf — same mechanism as today.

### Cross-chain invariants

- **The merkle root is byte-identical on every source chain.** A counterfactual's merkle tree contains the union of routes across _all_ source chains, with `block.chainid` in each leaf's preimage. On chain X, only leaves with `chainId == X` can be executed, but the **root** the dispatcher verifies against is the same value everywhere. This is what makes one CREATE2 derivation produce one address on every EVM chain.
- **The same property holds after migration.** Admin's meta-merkle tree maps each clone address to its target merkle root — and that target root is, again, a union-across-chains tree. Since a given identity's clone has the same address on every chain, one admin-published metaRoot leaf authorizes migration on every chain. After migration, every chain's clone for that identity holds the same `merkleRoot`.
- **Migrations apply per chain.** Each chain's registry is independent ([D12](#d12-each-chains-counterfactualmigrationregistry-is-independent)). Admin sets `metaRoot` on every chain (manually or via a cross-chain governance message). An executor calls `migrate` on each clone separately.

### Differences from the original counterfactual system

| Property                             | Original                                                        | New                                                                                                                    |
| ------------------------------------ | --------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------- |
| Clone's immutable arg                | `merkleRoot` (32 bytes)                                         | None (bare EIP-1167 proxy; address itself identifies the clone)                                                        |
| CREATE2 derivation                   | depends on `merkleRoot`                                         | depends on `keccak256(identityHash, initialRoot)`                                                                      |
| Same address across source chains?   | No — each chain's tree had different leaves → different roots   | **Yes** — root is byte-identical on every chain via `chainId`-in-leaf                                                  |
| Add a route after deploy?            | No — would change the merkle root and thus the address          | **Yes** — admin publishes a new metaRoot; executor calls `migrate`                                                     |
| Add a new source chain after deploy? | No                                                              | **Yes** — clone is "pre-live" at the same address on every EVM chain; deploy + immediate `migrate` brings it online    |
| Where does `merkleRoot` live?        | In the clone's CREATE2 immutable arg (frozen)                   | In clone storage (one slot, [D3](#d3-merkle-root-lives-in-storage-not-in-immutable-args))                              |
| `executionFee`                       | Committed in leaf params (static for the life of the address)   | Signer-signed at execute time (dynamic per fill, [D8](#d8-dynamic-executionfee-across-all-three-bridges))              |
| CCTP/OFT impl-level signature        | None — SrcPeriphery is the only signature checker               | Independent EIP-712 signer ([D11](#d11-cctpoft-impl-signer-is-independent-from-the-srcperiphery-signer))               |
| `paramsHash` bound in typehash?      | SpokePool only                                                  | All three impls ([D9](#d9-bind-paramshash-in-every-impls-eip-712-typehash))                                            |
| Governance contract                  | None                                                            | `CounterfactualMigrationRegistry` ([D5](#d5-meta-merkle-root-lives-in-a-separate-counterfactualmigrationregistry))     |
| Front-run protection at deploy       | Implicit (root in CREATE2 args)                                 | Same property via `initialRoot` in CREATE2 salt ([D2](#d2-initialroot-is-folded-into-the-create2-salt)); no admin gate |
| Address depends on `block.chainid`?  | Implicitly (per-chain trees produced per-chain roots/addresses) | No — `block.chainid` is checked at execute time, not address-derivation time                                           |

## Architecture Overview

```
            CounterfactualMigrationRegistry  (NEW — same address on every chain)
            - bytes32 metaRoot                (admin-set; auth root for migrations only)
            - setMetaRoot(bytes32)
                              ^
                              | reads metaRoot at migrate-time
                              |
   CounterfactualDepositFactory  (MODIFIED)
   - deploy(identity, initialRoot)                 <-- permissionless; no admin proof needed
   - deployAndExecute / deployIfNeededAndExecute
   - execute(depositAddr, calldata)
   - predictDepositAddress(identity, initialRoot)  <-- address depends on BOTH
                              |
                              v
   CounterfactualDeposit  (MODIFIED — merkle-dispatched proxy)
   - no immutable args (bare EIP-1167 proxy; address(this) identifies the clone)
   - salt (at CREATE2):    keccak256(identityHash, initialRoot)
   - storage: bytes32 merkleRoot
   - execute(impl, params, submitterData, proof)   <-- proves against merkleRoot
   - migrate(newRoot, metaProof)                   <-- proves leaf against registry.metaRoot, sets merkleRoot
                              |
       +----------------------+----------------------+-------------------+
       v                      v                      v                   v
   CCTP impl            OFT impl             SpokePool impl       Withdraw impl
   (+ EIP-712 sig)      (+ EIP-712 sig)      (sig expanded)       (unchanged)
```

All three deposit implementations now verify an EIP-712 signature over execution-time fields including `executionFee`. The dispatcher's leaf preimage also expands to include `block.chainid`.

## Address Derivation

Every contract in the system uses CREATE2 via the universal deterministic deployer (`0x4e59…956C`) so that addresses are reproducible on every EVM chain. CREATE2 derives an address from three inputs:

```
address = keccak256(0xff, deployer, salt, keccak256(initCode))[12:]
```

For an address to be the same on chain A and chain B, all three inputs must be byte-identical on both chains. We use the same deployer everywhere; we choose the salts; the per-contract sections below explain how each contract's `initCode` is kept identical across chains.

### CounterfactualMigrationRegistry

```
deployer  = 0x4e59…956C                                      // universal
salt      = TBD (chosen once; see Q1)
initCode  = registry bytecode  +  abi.encode(initialOwner, initialMetaRoot)
```

- **Bytecode is identical** — single source file, compiler version pinned in `foundry.toml`.
- **Constructor args must be byte-identical across chains:**
  - `initialOwner` — must be a globally consistent address on every chain. Two practical options: (a) a Safe multisig deployed deterministically (Safe's factory + the same setup script → the same address on every chain); (b) a known bootstrap EOA the team controls, used for initial deploy and immediately handed off via `transferOwnership`.
  - `initialMetaRoot` — typically `bytes32(0)` at genesis; the owner publishes the first real metaRoot via `setMetaRoot` once all chains are live.
- Anyone trying to deploy with different args produces different `initCode` → a different address → lands at an unused address. This is the [D14](#d14-registry-takes-initialowner-and-initialmetaroot-as-constructor-args) front-run mitigation.

### CounterfactualDeposit (dispatcher)

```
deployer  = 0x4e59…956C
salt      = TBD
initCode  = dispatcher bytecode  +  abi.encode(migrationRegistry)
```

- **Bytecode is identical** — single source, pinned compiler.
- **Constructor arg `migrationRegistry`** = the registry's globally-consistent address from above. Since the registry is at the same address on every chain, this arg is the same everywhere → dispatcher `initCode` is identical → dispatcher address is global.

### CounterfactualDepositFactory

```
deployer  = 0x4e59…956C
salt      = TBD
initCode  = factory bytecode  +  abi.encode(dispatcher)
```

- **Bytecode is identical** — single source, pinned compiler.
- **Constructor arg `dispatcher`** = the dispatcher's global address from above. Same on every chain.

### Clones (per-identity counterfactual instances)

```
deployer     = factory                                           // global address from above
salt         = keccak256(abi.encode(identityHash, initialRoot))
identityHash = keccak256(abi.encode(recipient, dstChainId, outputToken))
initCode     = EIP-1167 proxy(dispatcher)                        // bare 45-byte minimal proxy, no immutable args
```

- `recipient` is a `bytes32` (Across convention — supports non-EVM recipients).
- `dstChainId` is a `uint256`.
- `outputToken` is a `bytes32` (Across convention — supports non-EVM destination tokens).
- `initialRoot` is the canonical merkle root for this identity, published by the SDK. It is **byte-identical on every chain** (the tree's `block.chainid`-in-leaf design lets one root enumerate routes for all chains — see [Merkle Tree Structure](#merkle-tree-structure)).
- **EIP-1167 proxy target** = the dispatcher's global address from above.
- **No immutable args.** The clone is a bare minimal proxy. The CREATE2 salt encodes `(identityHash, initialRoot)`, so the address itself is the unique handle — `migrate` keys its meta-leaf on `address(this)` rather than on a decoded `identityHash`.
- `initialRoot` is folded into the CREATE2 **salt**. A malicious deployer using a different `initialRoot` produces a different salt → different CREATE2 address → no collision with the honest predicted address. This is the [D2](#d2-initialroot-is-folded-into-the-create2-salt) front-run mitigation.
- The clone's merkle root lives in **storage**, not in `initCode`, so migrations don't disturb the address.

All inputs are globally consistent → clones derive to the same address on every EVM chain.

### Bridge implementations (`CounterfactualDepositSpokePool` / `CCTP` / `OFT`)

These contracts hold chain-specific configuration (SpokePool address, signer, srcPeriphery, sourceDomain, srcEid, wrappedNativeToken). Their constructor args differ per chain, so their **addresses differ per chain** by design.

This is intentional and harmless: clones don't reference bridge implementations through `migrationRegistry` or `dispatcher`. They get implementation addresses from leaves inside the merkle tree, and each leaf includes `block.chainid` in its preimage so chain-X's leaves carry chain-X's specific impl addresses. The genesis tree enumerates per-chain impl addresses explicitly.

### Withdraw and admin contracts

- **`WithdrawImplementation`** has no constructor args → bytecode-only `initCode` → same address on every chain. Referenced via the withdraw leaf in each clone's tree.
- **`AdminWithdrawManager`** has chain-specific constructor args (per the existing deployment script). Address differs per chain; referenced through the withdraw leaf's `admin` field, so per-chain values are explicit at tree-construction time.

### Deployment ordering

Each contract's address depends on the previous one's, so the bootstrap is staged:

1. **Pick globally-consistent values:** `initialOwner` for the registry; salts for registry / dispatcher / factory.
2. **Compute predicted addresses** of registry, dispatcher, and factory using CREATE2 derivation (off-chain). At this point we know every address that will exist on every chain.
3. **Deploy in any order via the deterministic deployer.** Each call to `0x4e59…956C` with the chosen salt + initCode lands the contract at its predicted address. Already-deployed contracts are auto-skipped — repeating the call is a no-op.
4. **Bridge implementations and `AdminWithdrawManager` deploy per chain** using chain-specific constructor args from `script/counterfactual/config.toml`.
5. **Owner publishes the genesis `metaRoot`** via `registry.setMetaRoot(...)` once all chain registries are live.

### Tron divergence

Tron uses Tron-specific dispatcher and factory variants ([D10](#d10-tron-clones-break-cross-chain-address-equality-with-evm-clones)) — different bytecode → different `initCode` → different CREATE2 addresses than the EVM versions. Tron clones therefore live at different addresses than their EVM counterparts for the same identity; this is accepted. The Tron registry is independent ([D12](#d12-each-chains-counterfactualmigrationregistry-is-independent), Q3).

## Merkle Tree Structure

Each leaf commits to the **executing chain** via `block.chainid`, so the same merkle root validly authorizes routes across every supported source chain:

```solidity
leaf = keccak256(bytes.concat(keccak256(abi.encode(block.chainid, implementation, keccak256(params)))));
```

> **Cross-chain root invariant.** For a given counterfactual identity, the merkle root is **byte-identical on every source chain**. The tree enumerates the union of routes across _all_ source chains; on chain X, only leaves with `chainId == X` can be proved at execute time, but the root the dispatcher verifies against is the same value everywhere. This invariant is what lets a single CREATE2 derivation produce the same clone address on every EVM chain (see [Address Derivation](#address-derivation)) and is preserved across migrations — every metaRoot leaf points to an operational root that itself contains all-chain routes.

A tree contains:

| Leaf type      | Count                                                       | `params`                         |
| -------------- | ----------------------------------------------------------- | -------------------------------- |
| Deposit leaves | `Σ (srcChains × supportedInputsForOutput × bridges)`        | bridge-specific `*DepositParams` |
| Withdraw leaf  | 1 per `(admin, user)` configuration (typically 1 per clone) | `WithdrawParams{admin, user}`    |
| Padding        | as needed to pow-2                                          | —                                |

Because `inputToken` is in the leaf preimage (not the clone identity), a clone accepts every input enumerated in its current `merkleRoot`. To add support for a new input, the admin publishes a new metaRoot that maps each affected clone address to a new merkle root.

## Migration Mechanism

### CounterfactualMigrationRegistry (new contract)

```solidity
contract CounterfactualMigrationRegistry {
  address public owner; // multisig, optionally fronted by a TimelockController
  bytes32 public metaRoot; // current admin-approved meta-merkle root (governs migrations)

  event MetaRootUpdated(bytes32 oldRoot, bytes32 newRoot);

  function setMetaRoot(bytes32 newRoot) external onlyOwner;
  function transferOwnership(address newOwner) external onlyOwner;
}
```

- No constructor args → same CREATE2 address on every chain (deployed via the deterministic deployer at `0x4e59…956C`).
- `owner` is set post-deploy (e.g., transferred from deployer to a multisig/timelock per chain, matching the `AdminWithdrawManager` pattern).
- Single mutable storage slot (`metaRoot`) keeps the audit surface tiny.
- The registry governs **migrations only**, not initial deploys (front-run protection comes from `initialRoot` being in the CREATE2 salt — see [Address Derivation](#address-derivation)).
- Cross-chain consistency of `metaRoot` is an operational concern — the admin sets the same root on every chain when publishing an upgrade.

### Meta merkle leaf format

```solidity
metaLeaf = keccak256(bytes.concat(keccak256(abi.encode(cloneAddress, newRoot))));
```

- `cloneAddress` — the clone's CREATE2 address (the dispatcher reads this as `address(this)` at migrate time). Since each `(identityHash, initialRoot)` pair maps to a unique address, the address is itself a fine-grained identity.
- `newRoot` — the operational root to install.

A clone migrates to `newRoot` iff `(cloneAddress, newRoot)` is a leaf in the registry's **current** `metaRoot`. There is no on-chain version counter; replay protection comes from the fact that only the current `metaRoot` produces valid proofs. As soon as admin calls `setMetaRoot` with a new value, every proof against the previous metaRoot stops verifying.

**Admin convention:** the off-chain meta-tree builder publishes at most one leaf per clone address per metaRoot. The contract does not enforce this — if admin published two leaves for the same clone (say `(addr, R1)` and `(addr, R2)`), either could be applied. Admin tooling guarantees this single-leaf-per-clone invariant.

**Rollback is an explicit admin action, not a replay.** If admin needs to revert a clone from `R2` back to `R1`, they publish a new metaRoot containing the leaf `(addr, R1)`. That is intentional. There is no contract-level rejection of "moving backward" because there is no on-chain notion of "forward."

### CounterfactualDeposit (modified dispatcher)

```solidity
contract CounterfactualDeposit {
  // Single storage slot. merkleRoot != 0 doubles as the "initialized" sentinel.
  bytes32 public merkleRoot;

  receive() external payable {}

  function initialize(bytes32 initialRoot) external {
    if (merkleRoot != bytes32(0)) revert AlreadyInitialized();
    if (initialRoot == bytes32(0)) revert InvalidInitialRoot();
    merkleRoot = initialRoot;
  }

  function execute(
    address implementation,
    bytes calldata params,
    bytes calldata submitterData,
    bytes32[] calldata proof
  ) external payable {
    bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(block.chainid, implementation, keccak256(params)))));
    if (!MerkleProof.verify(proof, merkleRoot, leaf)) revert InvalidProof();
    (bool ok, bytes memory ret) = implementation.delegatecall(
      abi.encodeCall(ICounterfactualImplementation.execute, (params, submitterData))
    );
    if (!ok) {
      assembly {
        revert(add(ret, 32), mload(ret))
      }
    }
  }

  function migrate(bytes32 newRoot, bytes32[] calldata metaProof) external {
    if (newRoot == merkleRoot) revert NoOpMigration();
    bytes32 metaLeaf = keccak256(bytes.concat(keccak256(abi.encode(address(this), newRoot))));
    bytes32 metaRoot = ICounterfactualMigrationRegistry(MIGRATION_REGISTRY).metaRoot();
    if (!MerkleProof.verify(metaProof, metaRoot, metaLeaf)) revert InvalidMetaProof();
    merkleRoot = newRoot;
    emit Migrated(newRoot);
  }
}
```

Notes:

- `MIGRATION_REGISTRY` is a compile-time constant — the deterministic address of the registry, identical on every chain.
- `migrate` is permissionless: anyone with a valid proof against the current `metaRoot` can execute it (the "executor" role from the requirements).
- Replay of stale meta-leaves is blocked by the registry's "current root only" model: as soon as admin calls `setMetaRoot`, every proof against the prior `metaRoot` stops verifying.
- The clone has no immutable args at all (bare EIP-1167 proxy) — `address(this)` is the clone's identity. Saves ~32 bytes of clone bytecode compared to the old design.
- Total clone storage: one slot (`merkleRoot`). `merkleRoot != 0` doubles as the "initialized" sentinel since a zero root is rejected at `initialize` time (and would be useless anyway — it would authorize no leaves).

### Initial deployment

Deployment is permissionless. The factory CREATE2s the clone at a salt derived from `(identityHash, initialRoot)` and atomically installs `initialRoot` as the genesis `merkleRoot`:

```solidity
function deploy(bytes32 identityHash, bytes32 initialRoot) public returns (address depositAddress) {
  bytes32 salt = keccak256(abi.encode(identityHash, initialRoot));
  depositAddress = Clones.cloneDeterministic(DEPOSIT_DISPATCHER, salt);
  CounterfactualDeposit(payable(depositAddress)).initialize(initialRoot);
  emit DepositAddressCreated(depositAddress, identityHash, initialRoot);
}
```

- No admin proof required. Front-running with a malicious `initialRoot` produces a different CREATE2 address and cannot collide with the honest predicted address.
- The factory and dispatcher have no constructor args → same addresses on every EVM chain → same `cloneAddress` for the same `(identityHash, initialRoot)` everywhere.
- `initialize` is guarded by `_initialized` and called by the factory in the same transaction as `CREATE2`, so no one can install a different `initialRoot` into the slot the factory targets.
- The clone is "pre-live" on every EVM chain from the moment its identity is conceived: anyone can call `deploy(identityHash, initialRoot)` on a new chain and get the same address. Followed by a `migrate()` if the operational root has evolved past the genesis root, that chain's clone joins the live set without users re-funding a new address.

### Withdraw / refund flow (unchanged)

Unsupported inputs are refunded via the existing withdraw mechanism:

- Every operational root contains a `WithdrawImplementation` leaf with `{admin, user}` (typically `admin = AdminWithdrawManager`).
- `directWithdraw` (admin-bot) and `signedWithdrawToUser` (admin-signed) paths recover any token at the clone, including tokens that have no deposit leaf.
- This is the same path used today; no contract changes.

## Implementation Plan

Ordered by dependency, smallest changes first. Each step is a separate commit.

### 1. New: `CounterfactualMigrationRegistry.sol`

- ~60 lines. `owner`, `metaRoot`, `setMetaRoot`, `transferOwnership`, events.
- No constructor args → same address everywhere.
- Co-locate with `AdminWithdrawManager.sol`; same deployment pattern (post-deploy ownership transfer to the per-chain `ownerAndDirectWithdrawer` from `script/counterfactual/config.toml`).

### 2. Modified: `CounterfactualDeposit.sol`

- Add storage: `merkleRoot` (single public slot; `!= 0` doubles as the "initialized" sentinel).
- Add `initialize(bytes32)` (factory-only via implicit ordering, see step 3). Rejects `bytes32(0)` and re-initialization.
- Change `execute` leaf preimage to include `block.chainid`.
- Read `merkleRoot` from storage. No immutable args on the clone — the meta-leaf in `migrate` keys on `address(this)`.
- Add `migrate(bytes32 newRoot, bytes32[] proof)`.
- Add `MIGRATION_REGISTRY` constant (set at deploy via deterministic address).
- Add events: `Initialized(bytes32 initialRoot)`, `Migrated(bytes32 newRoot)`.
- Errors: `InvalidProof`, `InvalidMetaProof`, `AlreadyInitialized`, `InvalidInitialRoot`, `NoOpMigration`.

### 3. Modified: `CounterfactualDepositFactory.sol`

- Change `deploy` signature to `(bytes32 identityHash, bytes32 initialRoot)`.
- Salt = `keccak256(abi.encode(identityHash, initialRoot))`; no immutable args (use `Clones.cloneDeterministic` / `predictDeterministicAddress`).
- Call `initialize(initialRoot)` on the freshly deployed clone in the same tx (atomicity prevents anyone from racing into the `_initialized` slot with a different root).
- Update `predictDepositAddress(bytes32 identityHash, bytes32 initialRoot)` to take both.
- `deployAndExecute` / `deployIfNeededAndExecute` thread the new args.
- No registry/metaRoot interaction at deploy time — registry is only consulted by `migrate`.

### 4. Modified: `CounterfactualDepositFactoryTron.sol`

- Mirror step 3. Tron variant continues to use a Tron-specific dispatcher address (different EVM behavior for USDT).
- Note: Tron breaks cross-chain address equality. Document explicitly — Tron clones live at different addresses by design and are derived through the Tron factory.

### 5. Implementations (`CounterfactualDepositSpokePool/CCTP/OFT`) — dynamic `executionFee`

Move `executionFee` out of leaf `params` and into a signer-signed submitter payload across all three bridges. Each implementation gains (or, for SpokePool, expands) an in-impl EIP-712 verification step.

**Shared shape**

- New constant per impl: `address public immutable signer` (same configuration mechanism as today's SpokePool impl).
- EIP-712 domain uses `address(this)` (the clone) → cross-clone replay prevention; no nonce needed (deadline + token-balance consumption bound the replay window).
- Typehash binds, at minimum: every signed amount/fee field, `executionFeeRecipient`, the route's `paramsHash`, and `signatureDeadline`. Binding `paramsHash` prevents the cross-leaf attack flagged in `DESIGN_COMPARISON.md` §"Per-bridge considerations" if a clone ever ends up with multiple leaves on the same impl.

**`CounterfactualDepositSpokePool`**

- Today's typehash already covers `inputAmount`, `outputAmount`, etc. but does **not** commit to `paramsHash`. Expand to include `paramsHash` and `executionFee`.
- Move `executionFee` from `SpokePoolDepositParams` → `SpokePoolSubmitterData`.
- Update `_checkFee` to read `executionFee` from submitter data.

**`CounterfactualDepositCCTP`**

- Add a `signer` immutable and EIP-712 verification step before forwarding to `SponsoredCCTPSrcPeriphery.depositForBurn`.
- Move `executionFee` from `CCTPDepositParams` → `CCTPSubmitterData`.
- The SrcPeriphery's own signature still binds the `SponsoredCCTPQuote`; the new impl-level signature additionally binds `executionFee` and the local route's `paramsHash`. The two signatures can share a signer or be split — design choice listed as open question.

**`CounterfactualDepositOFT`**

- Mirrors CCTP: add `signer` immutable + EIP-712 verification, move `executionFee` to submitter data, additional signature binds the local route's `paramsHash` plus `msg.value` allotment for LZ messaging fees.

**Implications**

- Per-execute calldata grows by one signature (~65 bytes) and one or two amount fields. Negligible vs. bridge call cost.
- Off-chain signer service now signs CCTP and OFT executes in addition to SpokePool. It's the same signer abstraction — just an extra route type.
- This is independent of the migration mechanism: even without root upgrades, dynamic `executionFee` is now a first-class feature.

### 6. Tests (`test/evm/foundry/local/`)

- Migration happy path: `migrate` flips operational root; subsequent `execute` proves against new root.
- Stale metaRoot rejection: after admin calls `setMetaRoot(newMetaRoot)`, proofs against the prior metaRoot no longer verify.
- No-op migration rejection: calling `migrate(currentRoot, proof)` reverts (`NoOpMigration`).
- Initialization guard: `initialize` rejects `bytes32(0)`; second `initialize` call reverts.
- Cross-chain leaf isolation: a leaf with `block.chainid = A` cannot be executed on chain `B`.
- Front-run protection: deploying with a different `initialRoot` produces a different address and does not affect the honest predicted address; `initialize` cannot be re-called once set.
- Same-address invariant: predict on multiple `block.chainid` values yields the same address for the same `(identityHash, initialRoot)` pair (use `vm.chainId`).
- Pre-live property: deploy + immediate `migrate` on a chain not present in the genesis enumeration brings that chain's clone live at the same address.
- Dynamic `executionFee`: signer can vary `executionFee` across executes without re-deploying; tampered `executionFee` (mismatched signature) reverts; bound enforcement (per-bridge `maxFee*` caps) still applies to the new signed value.
- Cross-leaf safety: with `paramsHash` bound in each typehash, a signature for route A cannot authorize a fill of route B even on the same impl.
- Existing CCTP/OFT/SpokePool integration tests updated for the new signature requirement and the relocated `executionFee` field.

### 7. Deployment scripts (`script/counterfactual/`)

- Add `DeployMigrationRegistry.s.sol` (deterministic, ownership transferred to admin post-deploy).
- Update `DeployAllCounterfactual.s.sol` to deploy the registry, and to inject the registry address into `CounterfactualDeposit`'s constants file before compilation (or read from `broadcast/deployed-addresses.json` and require equality at deploy time).
- Update `config.toml` with a per-chain `migrationRegistryOwner` (often = `ownerAndDirectWithdrawer`).

### 8. Documentation

- Update `README.md` "Architecture" + "Merkle Tree Structure" + "Deployment" sections.
- Update `DESIGN_COMPARISON.md` to note that Enumerated Routes now survives most catalog updates via root migration (one of the previous "no" entries in the durability table flips to "yes — via root migration").
- New `MIGRATIONS.md` (lightweight runbook): how admin builds a meta-merkle, signs it, publishes via `setMetaRoot`, and communicates the proof set to executors.

## Estimated Sizing

| Concern                          | Delta vs. current Enumerated Routes                               |
| -------------------------------- | ----------------------------------------------------------------- |
| New contracts                    | 1 (`CounterfactualMigrationRegistry`, ~60 LoC)                    |
| Modified contracts               | 2 (`CounterfactualDeposit`, `CounterfactualDepositFactory[Tron]`) |
| New storage per clone            | 1 slot (`merkleRoot`; doubles as initialized sentinel)            |
| Extra runtime cost per `execute` | +1 SLOAD (operational root) — negligible vs. bridge call          |
| Extra runtime cost per `migrate` | ~1 cold SLOAD on registry + MerkleProof.verify                    |
| Deploy gas per clone             | ≈ unchanged (immutable arg still 32 bytes)                        |
| Audit surface delta              | ~150 LoC (registry + dispatcher edits)                            |

## Open Questions

Working assumptions we have not yet committed to. Each lists what we're currently planning and what's still up in the air. Locked-in decisions live under [Design Decisions](#design-decisions).

1. **Migration registry address pinning.**
   _Working assumption:_ deploy `CounterfactualMigrationRegistry` via the deterministic deployer (`0x4e59…956C`) with a chosen salt, compute the resulting address, embed it as the `MIGRATION_REGISTRY` compile-time constant in `CounterfactualDeposit`. No router or proxy — the registry is single-purpose, and a fresh deployment with different logic would change every clone's address. The specific salt value needs to be chosen before dispatcher source is finalized.
   _Alternatives:_ (a) put the registry behind a router that the dispatcher reads (would let us swap registry implementations without breaking clone addresses, at the cost of an extra contract + indirection + audit surface); (b) make the registry address a runtime parameter at dispatcher construction (breaks dispatcher's cross-chain address invariant since immutable args would differ).

2. **New-chain onboarding entrypoint.**
   _Working assumption:_ add `factory.deployAndMigrateAndExecute(identityHash, initialRoot, newOperationalRoot, migrateProof, executeCalldata)` as a convenience entrypoint that atomically CREATE2s the clone, calls `initialize(initialRoot)`, calls `migrate(newOperationalRoot, migrateProof)`, then forwards the execute calldata. Makes the "pre-live on every EVM chain" property ergonomic for relayers handling deposits on chains that weren't enumerated at genesis.
   _Alternatives:_ (a) require callers to compose `deploy + migrate + execute` separately (more flexible, more calldata, harder for relayers); (b) expect SDK to use a generic multicall contract (avoids new factory entrypoint but adds an external dependency to the deposit hot path).

3. **Tron's migration registry is independent from EVM's.**
   _Working assumption:_ deploy a separate `CounterfactualMigrationRegistryTron` (same logic, separate deployment) governing Tron clones. Admin maintains a Tron-specific metaRoot whose leaves point to Tron impl addresses. Tron clones already live at different addresses than EVM clones for the same identity ([D10](#d10-tron-clones-break-cross-chain-address-equality-with-evm-clones)), so cross-registry sharing wouldn't apply anyway.
   _Alternatives:_ (a) share registry logic via one global contract reading a chain-id flag (rejected by working assumption — adds complexity for no operational benefit, since the meta-roots differ anyway); (b) skip Tron's registry entirely and pin Tron clones at their genesis root (rejected by working assumption — gives up upgradability for the Tron flow).

4. **Stale-root execution between `setMetaRoot` and per-clone `migrate`.**
   _The gap:_ `execute()` verifies proofs against the clone's own `merkleRoot` in storage, with no consult of the registry. Between admin calling `setMetaRoot(newMetaRoot)` and a given clone being migrated, executors can keep running deposits against the old root. For purely additive upgrades (adding a token, widening fee bounds) this is harmless. For revocation-style upgrades — signer rotation after compromise, periphery deprecation, fee-bound tightening, withdraw-admin rotation — it leaves a window where the old config is still executable on unmigrated clones, with implications proportional to the urgency of the revocation.
   _Working assumption:_ accept the gap; rely on an off-chain sweeper bot that watches `MetaRootUpdated` events and immediately calls `migrate()` on every affected clone. Monitor metaRoot lag in a dashboard. Document the revocation latency as an operational property.
   _Alternatives:_ (a) **Direct-mapping registry** — registry stores `mapping(identityHash => approvedRoot)` instead of a meta-merkle root; `execute()` reads the approved root from the registry every time. Adds ~2.1k cold-SLOAD per execute and gives up batched admin updates (per-identity admin txs), but stale-root execution becomes structurally impossible. (b) **Execute-time consistency check** — clones keep their own root but `execute()` requires `merkleRoot == registry.approvedRoot(identityHash)` and reverts otherwise, forcing a `migrate()` first. Same cost as (a). (c) **Pointer-based architecture** — clones point at a policy address (per the broader route-policy discussion); admin upgrades the policy in one tx and every pointing clone is affected immediately. Bigger redesign but cleanly eliminates this class of issue.

5. **Label-only address derivation vs. keeping `initialRoot` in the salt.**
   _The proposal:_ derive the clone address purely from a versioned identity "label" (e.g., `keccak256("counterfactual:v1", recipient, dstChainId, outputToken)`) and drop `initialRoot` from CREATE2 input entirely. Cleaner address-derivation story, easier off-chain prediction (no need to publish per-identity `initialRoot` values), pairs naturally with a policy-design refactor where the registry is the source of truth for config.
   _Working assumption:_ keep `initialRoot` in the salt as in [D2](#d2-initialroot-is-folded-into-the-create2-salt). The cryptographic anchor between address and original config is what protects the pre-deploy funding window without any governance dependency — different `initialRoot` produces a different address, so a malicious deployer can't collide with what an honest user funded. Dropping it shifts that guarantee from math to "trust the registry's state at the moment of deploy," which is fine in a policy-design world but a regression in the current per-counterfactual-root model.
   _Alternatives if we adopted label-only:_ (a) **Admin-gated deploy** — factory requires admin signature or registry proof at deploy; deploys are no longer self-service. (b) **Registry-driven initial config** — `factory.deploy(label)` reads the canonical root/policy from the registry; no caller-supplied root exists. (c) **No initial root at all** — clones start with `merkleRoot = bytes32(0)` and require a `migrate()` before first execute. Each of these closes the front-run gap that the salt currently closes cryptographically. Worth revisiting if [Q4](#open-questions) drives us toward a direct-mapping registry or policy-design refactor.
   _Independent of the larger decision:_ the **`"counterfactual:v1"` prefix in `identityHash` is worth adding regardless.** It costs nothing and gives a clean v2 migration path if the schema ever changes — v2 clones derive from a different prefix and can't collide with v1 addresses.

## Design Decisions

A running log of locked-in choices. Each entry: decision, rationale, alternatives considered. Open items live under [Open Questions](#open-questions).

### D1. Address identity = `(recipient, dstChainId, outputToken)`

The CREATE2 derivation depends on these three fields and nothing else from the user's identity (e.g., no per-user signer, no per-deal admin).

**Rationale:** Matches the stated requirement directly. Two depositors targeting the same destination get distinct addresses; the same depositor across multiple destinations gets distinct addresses; the same `(recipient, dstChain, outputToken)` triple is portable across source chains.

**Alternatives considered:** add `admin`/`signer` to the identity (rejected — fragments address space without a clear use case); use only `(recipient, dstChain)` and let `outputToken` be selected at execute time (rejected — would re-introduce volatile-swap ambiguity).

### D2. `initialRoot` is folded into the CREATE2 salt; clones carry no immutable args

`salt = keccak256(identityHash, initialRoot)`; clones are bare EIP-1167 proxies with no appended immutable args. `migrate` keys its meta-leaf on `address(this)` rather than on a decoded `identityHash`.

**Rationale:** Lets the factory accept a permissionless `deploy(identityHash, initialRoot)` without any registry pre-loading. A malicious deployer using a different `initialRoot` produces a different address, so an honest user's pre-funded predicted address can't be hijacked. Cross-chain address equality holds because the genesis tree uses `chainId`-in-leaf, so the same `initialRoot` is valid on every chain. Dropping the immutable arg (which originally held `identityHash`) is a small simplification: each clone address is itself a one-way function of `(identityHash, initialRoot)`, so the address alone uniquely identifies the clone — no need to recover `identityHash` at runtime. Saves ~32 bytes of clone bytecode (slightly lower deploy gas) and removes an `extcodecopy + abi.decode` in `migrate`.

**Alternatives considered:**

- _Identity-only salt, `metaProof` gates deploy_ — rejected because it forced the admin to pre-publish every `(identityHash, initialRoot)` pair before its owner could deploy, killing self-service issuance and putting the full recipient set on-chain.
- _Identity-only salt, no metaProof_ — rejected because a front-runner could deploy a malicious clone at the predicted address before the honest user.
- _Both `identityHash` and `initialRoot` in immutable args_ — equivalent security; rejected as marginally larger clone bytecode for no benefit (`initialRoot` is recoverable from genesis events; `identityHash` isn't needed at runtime now that meta-leaves are address-keyed).
- _`identityHash` in immutable args, meta-leaf keyed on `identityHash`_ — equivalent security but adds 32 bytes of clone bytecode and an `extcodecopy` on every migrate, in exchange for slightly broader authorization (one meta-leaf covers all clones sharing an identity even if they differ in `initialRoot`). Rejected for simplicity; the address-keyed form requires admin to enumerate clones individually in the meta-tree, which is already the natural workflow.

### D3. Merkle root lives in storage, not in immutable args

Clones expose `merkleRoot` as their only (public) storage slot; the dispatcher reads it at execute time. A non-zero value also serves as the "initialized" sentinel.

**Rationale:** The whole point of the upgrade story. If the root were in immutable args, every migration would change the address.

**Alternatives considered:** keep root in immutable args, treat "upgrade" as deploying a new clone at a new address and re-pointing off-chain mappings — rejected because it breaks "deposit address lives forever".

### D4. `chainId` in every leaf preimage

`leaf = keccak256(bytes.concat(keccak256(abi.encode(block.chainid, implementation, keccak256(params)))))`.

**Rationale:** Lets one merkle root authorize routes on every source chain. Without this, each chain would need a different root → different addresses.

**Alternatives considered:** per-chain roots stitched together off-chain (rejected — defeats the cross-chain address invariant); chain-agnostic impls reading a registry (rejected — that's the "Registry Routes" design, larger contract diff and adds a global trust point, see `DESIGN_COMPARISON.md`).

### D5. Meta merkle root lives in a separate `CounterfactualMigrationRegistry`

A new single-purpose contract holds the admin-approved `metaRoot`. Clones read it at `migrate` time via a compile-time constant address.

**Rationale:** Keeps the factory logic-only and gives the governance surface a single, easily-monitored contract. Same deterministic-deploy pattern as `AdminWithdrawManager` — identical address on every chain.

**Alternatives considered:** fold metaRoot into the factory (rejected — mixes deployment plumbing with governance state); per-clone admin signature instead of registry (rejected — admin must sign every migration individually, no batch upgrades).

### D6. Replay protection comes from "registry holds the latest metaRoot only"

Meta leaf = `keccak256(identityHash, newRoot)` — no version field. The registry stores a single `metaRoot`. When admin calls `setMetaRoot(newMetaRoot)`, every proof against the previous metaRoot stops verifying because the merkle root the contract checks against has changed.

`migrate(currentRoot, …)` is rejected at the contract level (`NoOpMigration`) so a stale proof against the _current_ metaRoot can't be re-run for grief or events.

**Rationale:** Simplest design that preserves the security property. No version counter on clones (storage drops to one slot). No version field in the leaf. Admin's responsibility is to publish, in each new metaRoot, only the target roots for identities that should currently be at those roots — which is the natural off-chain construction anyway.

**Alternatives considered:**

- _Per-clone version counter (leaf = `(identityHash, version, newRoot)`)_ — rejected. Adds a storage slot per clone and a field per leaf to defend against a scenario (admin republishes an old metaRoot wholesale by mistake) that is itself an explicit admin action. Rollback also becomes a clunkier admin operation (must issue same root at higher version).
- _Previous-root anchoring (leaf = `(identityHash, previousRoot, newRoot)`)_ — rejected. Admin must know each clone's current root at meta-tree build time, adding off-chain coordination cost.
- _Direct mapping registry (`mapping(identityHash => latestRoot)`)_ — equivalent security but admin pays per-identity SSTORE; meta-merkle amortizes a batch into one `setMetaRoot` tx. We keep the merkle structure for batch efficiency.

**Trade-off accepted:** rollback by republishing an old leaf is permitted by the contract. Admin tooling must guard against accidental rollback; intentional rollback (e.g., to recover from a bad upgrade) is supported as a normal admin operation.

### D7. Migration is permissionless

`migrate()` on the dispatcher is callable by anyone who has a valid proof against the current `metaRoot`.

**Rationale:** Matches the "executor" role from the requirements — admin governs _what_ migrations are valid, anyone can _execute_ one.

**Alternatives considered:** whitelist (rejected — adds an operational role without security benefit, since admin already governs `metaRoot`); rate-limited (rejected — premature optimization).

### D8. Dynamic `executionFee` across all three bridges

`executionFee` moves from leaf `params` into a signer-signed submitter payload. CCTP and OFT implementations gain an in-impl EIP-712 verification step; SpokePool's existing typehash expands.

**Rationale:** Lets the off-chain quoter price each fill against live gas costs without re-issuing the deposit address (which would otherwise change because `executionFee` is in the leaf).

**Alternatives considered:** keep `executionFee` committed at address generation (rejected — gas costs vary too much; users would over-commit at genesis or be stranded later); pull live fee from an on-chain oracle (rejected — adds a global trust point for a problem a signed amount already solves).

### D9. Route binding in EIP-712 typehashes — `paramsHash` for SpokePool, `nonce` for CCTP/OFT

Each impl-level signature commits to enough route data to prevent cross-leaf replay even when multiple leaves on the same impl exist in a clone's tree. The exact field differs by bridge:

- **SpokePool** binds `paramsHash` (the leaf's `keccak256(params)`). There is no SrcPeriphery for SpokePool — the impl-level signature is the only signature gating the deposit, so it must commit directly to the route.
- **CCTP and OFT** bind `nonce` instead. The SrcPeriphery's quote signature already commits `(route, nonce)` together, so the local signature transitively pins the route through the periphery — and gets single-use replay protection for free, since the periphery consumes the nonce on first use.

**Rationale:** Removes the "no duplicate impls per clone" constraint cheaply (~500 gas/execute). Lets future trees include multiple SpokePool (or CCTP/OFT) routes — e.g., per supported input token — under one impl without cross-leaf signature replay risk. For CCTP/OFT, the asymmetry vs SpokePool is justified because the bridge layer already does the heavy lifting: binding `nonce` is sufficient and yields a smaller, simpler typehash.

**Alternatives considered:**

- _Bind `paramsHash` in CCTP/OFT too_ — more defensive but redundant given the SrcPeriphery quote already commits the route. Rejected because it adds typehash complexity for marginal protection (only useful if the SrcPeriphery's quote signature has a route-binding bug).
- _Preserve the "one impl per clone" invariant by SDK discipline instead_ — rejected. Invariant is easy to break; audit reviewers would have to verify it holds in every emitted tree.
- _Don't bind anything beyond `executionFee + signatureDeadline` on CCTP/OFT_ — rejected. Without nonce or paramsHash, the local signature is route-agnostic and could in principle be replayed across deposits with the same fee.

### D10. Tron clones break cross-chain address equality with EVM clones

Tron uses the Tron-specific factory + dispatcher. Tron clones live at different addresses than their EVM counterparts for the same identity.

**Rationale:** Tron USDT's non-standard `transfer` return value forces a different transfer hook in the implementation, which forces a different dispatcher address, which forces a different clone address. Constraining EVM to Tron compatibility would compromise EVM gas/cleanliness for no real benefit (Tron integrators already know they're on a separate codepath).

**Alternatives considered:** make the EVM dispatcher also handle Tron-style transfers (rejected — bloats every EVM execute with a branch that never fires).

### D11. CCTP/OFT impl signer is independent from the SrcPeriphery signer

The new EIP-712 signer added to `CounterfactualDepositCCTP` and `CounterfactualDepositOFT` (per [D8](#d8-dynamic-executionfee-across-all-three-bridges)) is a different key than the one that signs `SponsoredCCTPQuote` / OFT quotes inside the respective `SrcPeriphery`.

**Rationale:** Smaller blast radius on key compromise. The impl-level signer authorizes `executionFee` and per-route binding (`paramsHash`); the SrcPeriphery signer authorizes the bridge-level quote (amounts, nonces, deadlines). If one key leaks, the attacker only gains the authority of that signer — they can't simultaneously forge a bridge quote and a counterfactual execution. Each signer can be rotated independently.

**Alternatives considered:** share one signer for both (rejected — single key to rotate is operationally simpler but doubles the blast radius of any compromise; not worth the savings).

### D12. Each chain's `CounterfactualMigrationRegistry` is independent

The registry on chain A and the registry on chain B share an address (D5) but are not cryptographically linked. Admin updates `metaRoot` per chain — either via direct multisig transactions on each chain or via a cross-chain governance message.

**Rationale:** Simplest implementation; no in-contract cross-chain verifier needed for v1. Cross-chain consistency of `metaRoot` becomes an operational invariant the admin maintains. If the admin sets a different metaRoot on chain B than on chain A, only chain B's clones get the new migration set — incorrect but recoverable (admin updates chain A to match).

**Alternatives considered:** thread a single signed metaRoot through a verifier on each chain (rejected for v1 — adds a cross-chain message verifier as new audit surface; revisit only if operational drift becomes a real problem).

### D13. Withdraw leaf is fully mutable via root migration

The withdraw leaf (the `{admin, user}` pair gating fund recovery) is just another leaf in the operational root. Admin can rotate `admin`, `user`, or both via a normal `migrate()` — no special case in the dispatcher.

**Rationale:** Single mechanism for all root updates; no separate pinned-state or split-path code in the dispatcher. Lets admin upgrade `AdminWithdrawManager` to new versions over time and (with the user's cooperation) rotate the `user` escape-hatch address.

**Trade-off accepted:** `metaRoot` governance holds custody-equivalent authority. A malicious or compromised `metaRoot` admin can publish a migration that swaps `user → attacker` (removing the escape hatch) or `admin → attacker_admin` (taking direct custody). This is mitigated by — and explicitly relies on — `metaRoot` governance being operated as a custody-grade setup (high-bar multisig + timelock, giving users a window to call `user`-side withdraw before any migration takes effect).

**Alternatives considered:**

- _Pin the entire withdraw leaf at genesis_ — rejected. Strongest user guarantee but blocks all `AdminWithdrawManager` upgrades, requires an extra storage slot to store the pinned commitment, and forces re-funding new addresses for any custody-config change.
- _Pin only the `user` address, allow `admin` to mutate_ — rejected for v1 in favor of single-mechanism simplicity. Worth revisiting if `metaRoot` governance ends up lighter than custody-grade; in that case, asymmetric pinning is the right escape-hatch protection.
- _Mutable leaf but contract-level rejection of `user` changes_ — equivalent to the above; rejected for the same reason.

### D14. Registry takes `(initialOwner, initialMetaRoot)` as constructor args

`CounterfactualMigrationRegistry`'s constructor takes `(address initialOwner, bytes32 initialMetaRoot)` rather than setting `owner = tx.origin` with no args. For cross-chain address consistency, the same `(initialOwner, initialMetaRoot)` tuple is passed on every chain.

**Rationale:** A registry with no constructor args has identical `initCode` everywhere → identical CREATE2 address via the deterministic deployer. With `owner = tx.origin`, the first EOA to submit the deploy tx (anywhere) becomes permanent owner of the squatted registry on that chain, and any mempool watcher can race ahead of the legitimate deployer. Putting `initialOwner` in the constructor solves it cryptographically: anyone deploying with different args produces different `initCode` → lands at a different (unused) address. Including `initialMetaRoot` lets the bootstrap state be set atomically with deploy instead of in a separate transaction.

**Trade-off accepted:** `initialOwner` must be a globally consistent address on every chain — typically a Safe multisig deployed deterministically (same Safe factory + identical setup → same address), or a known bootstrap EOA that's handed off post-deploy via `transferOwnership`. This is the same operational pattern as `AdminWithdrawManager`'s deployer/owner.

**Alternatives considered:**

- _Set `owner = tx.origin` in constructor with no args_ — rejected (the original implementation). Critical front-run risk on every chain.
- _Custom factory that authenticates the deployer before deploying the registry_ — rejected. Workable but adds an extra contract to audit and another address to coordinate. Constructor-args achieves the same property with a smaller surface.
- _Admin-only deploy via a permissioned factory_ — rejected. Removes the "any chain, deterministic-deployer, no special setup" property that's the whole point of the universal deterministic-deployer pattern.
