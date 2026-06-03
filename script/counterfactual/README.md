# Counterfactual Deployment Scripts

Foundry scripts for deploying the counterfactual deposit-address system. Every contract is deployed
through the **deterministic-deployment proxy** (`0x4e59b44847b379578588920cA78FbF26c0B4956C`, "Nick's
factory") via CREATE2, so a given contract lands at the same address on every chain when its CREATE2
inputs are identical.

For the contract-level design, see
[`contracts/periphery/counterfactual/README.md`](../../contracts/periphery/counterfactual/README.md)
and [`RoutePolicies.md`](../../contracts/periphery/counterfactual/RoutePolicies.md). This doc covers
**deployment** and, above all, **how to keep clones at the same address across source chains**.

## The headline goal: same clone address on every chain

A user's counterfactual deposit address (the "clone") must resolve to the **same address on every
source chain** for a given clone identity. A CREATE2 address is
`keccak256(0xff ++ deployer ++ salt ++ keccak256(initCode))`, so a clone's address is a function of:

- the **CREATE2 deployer** — the `CounterfactualDepositFactory`;
- the **salt** — a standalone CREATE2 parameter (not part of init code; see `deploySalt` below); and
- the **init code** — the clone's creation bytecode, which is an EIP-1167 minimal proxy embedding
  the **`CounterfactualDeposit` dispatcher** address, with the 32-byte **`argsHash`** appended as
  immutable args. `argsHash = keccak256(abi.encode(outputToken, destinationChainId, recipient,
userAddress, routePolicyAddress))`.

(The salt is _not_ embedded in the proxy bytecode — only the dispatcher address is; the `argsHash`
is appended init-code bytes. Both still feed the address via the formula above.)

These are all controlled by the SDK/user and are naturally identical for a given identity, _except_
that the contract addresses feeding the formula — the factory (deployer), the dispatcher (embedded
in init code), and the RoutePolicy proxy (inside `argsHash`) — must themselves be uniform across
chains:

| Must be uniform across chains        | Why                                      | How it stays uniform                                 |
| ------------------------------------ | ---------------------------------------- | ---------------------------------------------------- |
| `CounterfactualDepositFactory`       | CREATE2 deployer of clones               | No constructor args → identical init code everywhere |
| `CounterfactualDeposit` (dispatcher) | Embedded in clone bytecode               | No constructor args → identical init code everywhere |
| **`RoutePolicy` proxy**              | It **is** `cloneArgs.routePolicyAddress` | Genesis-root + deployer-EOA-owner deploy (see below) |

Everything else the system deploys (`WithdrawImplementation`, `AdminWithdrawManager`, the bridge
impls) is **not** part of clone identity — those are referenced in the per-chain policy merkle tree,
not in `cloneArgs`. We still keep most of them uniform for operational convenience, but a divergence
there does **not** break clone-address consistency.

### Why the RoutePolicy needs special care

The `RoutePolicy` is a UUPS proxy. The proxy address is determined by its CREATE2 init code, which
embeds:

1. the **implementation address** (which itself embeds the `immutable` merkle root in its
   constructor), and
2. the proxy **init data** = `initialize(initialOwner)`.

If we deployed the proxy with each chain's _real_ root, the implementation bytecode (and thus its
address, and thus the proxy address) would differ per chain — **breaking clone consistency**.
Likewise if we used each chain's multisig as the genesis owner, the init data would differ.

So genesis deployment uses two **global** values:

- **genesis root = `bytes32(0)`** (`GENESIS_ROUTE_POLICY_ROOT` in `CounterfactualConfig.sol`), and
- **genesis owner = the deployer EOA** (derived from `MNEMONIC` index 0; the same address on every
  chain).

The real per-chain root is applied **after** genesis via `RotateRoutePolicyRoot`, which deploys a
new implementation carrying the real root and calls `upgradeToAndCall` on the proxy. That changes
the implementation behind the proxy but **not the proxy's address**, so clones are unaffected.
Ownership is transferred from the deployer EOA to the chain-local multisig as a post-deploy step
(also address-neutral).

> **Never bake a real (non-zero) root into the genesis `RoutePolicy` implementation, and never use a
> chain-specific genesis owner.** Either one gives the proxy a per-chain address and breaks
> clone-address consistency.

## Contracts and their address behavior

| Contract                             | Constructor args                                      | Same address across chains?        |
| ------------------------------------ | ----------------------------------------------------- | ---------------------------------- |
| `CounterfactualDeposit` (dispatcher) | none                                                  | Yes                                |
| `CounterfactualDepositFactory`       | none                                                  | Yes                                |
| `AdminWithdrawManager`               | `(deployer, deployer, signer)` — all global           | Yes                                |
| `WithdrawImplementation`             | `(adminWithdrawManager)` — global (manager is global) | Yes                                |
| `RoutePolicy` impl (genesis)         | `(bytes32(0))`                                        | Yes                                |
| `RoutePolicy` proxy                  | `(genesisImpl, initialize(deployerEOA))`              | **Yes** (the one that matters)     |
| `RoutePolicy` impl (post-rotation)   | `(realRoot)` — chain-specific                         | No (expected; proxy stays uniform) |
| `CounterfactualDepositSpokePool`     | `(spokePool, signer, wrappedNativeToken)`             | No (chain-specific)                |
| `CounterfactualDepositCCTP`          | `(srcPeriphery, sourceDomain)`                        | No (chain-specific)                |
| `CounterfactualDepositOFT`           | `(oftSrcPeriphery, srcEid)`                           | No (chain-specific)                |

### A note on the withdraw wiring (no circular dependency)

`WithdrawImplementation` takes the `AdminWithdrawManager` address as its `immutable admin`. The
manager does **not** store the impl address (the `withdrawImpl` is passed per call to the manager's
functions), so there is no construction cycle. Deploy order is free because the manager's address is
deterministic and predicted from `(deployer, deployer, signer)` — the withdraw impl can be deployed
before the manager exists. `CounterfactualConfig._predictAdminWithdrawManager` /
`_predictWithdrawImpl` are the single source of truth for these predictions.

## Files

- `CounterfactualConfig.sol` — shared config loader, CREATE2 init-code builders, and address
  predictions. The init-code builders (`_routePolicyProxyInitCode`, `_withdrawImplInitCode`, etc.)
  are the single source of truth used by both the deploy and predict paths.
- `DeployCounterfactualDeposit.s.sol` — dispatcher (no args).
- `DeployCounterfactualDepositFactory.s.sol` — factory (no args).
- `DeployAdminWithdrawManager.s.sol` — manager with `(deployer, deployer, signer)`.
- `DeployWithdrawImplementation.s.sol` — withdraw impl with `admin` = predicted manager.
- `DeployRoutePolicy.s.sol` — genesis RoutePolicy: impl (`bytes32(0)`) + ERC1967Proxy (owner = deployer EOA).
- `RotateRoutePolicyRoot.s.sol` — governance helper to activate / change a policy's root (post-genesis).
- `DeployCounterfactualDepositSpokePool.s.sol` / `...CCTP.s.sol` / `...OFT.s.sol` — bridge impls (chain-specific).
- `DeployAllCounterfactual.s.sol` — orchestrates the full per-chain deployment via `ffi`.
- `CheckCounterfactualDeployments.s.sol` — cross-chain verification.
- `config.toml` — global `deploySalt` and `signer`, plus per-chain `ownerAndDirectWithdrawer` (the chain-local multisig).

## Deployment process

### 1. Configure

Edit `config.toml`.

Top-level (global, applies to all chains):

- `deploySalt` — optional CREATE2 salt for every counterfactual contract. Defaults to `bytes32(0)`
  if omitted. Keep it identical across chains (it's a single top-level key, so it is by
  construction). Change it only for a deliberate fresh redeploy at new addresses everywhere.
- `signer` — required EIP-712 signer for execution fees / signed withdrawals. A single top-level key
  (not per-chain), so it is uniform across chains by construction — it feeds the
  `AdminWithdrawManager` init code, keeping that contract's CREATE2 address identical everywhere (it
  also feeds the chain-specific bridge impls, which vary by chain regardless).

Per chain (`[chainId.address]`):

- `ownerAndDirectWithdrawer` — the chain-local multisig. Receives `AdminWithdrawManager`
  owner/directWithdrawer roles **and** `RoutePolicy` proxy ownership in the post-deploy transfer step.

### 2. Deploy (per chain)

```bash
source .env   # MNEMONIC="...", ETHERSCAN_API_KEY="..."
forge script \
  script/counterfactual/DeployAllCounterfactual.s.sol:DeployAllCounterfactual \
  --sig "run(string,bool,bool,bool,bool,bool,string)" \
  <rpcUrl> <deploySpokePool> <deployCctp> <deployOft> <transferRoles> <broadcast> counterfactual \
  --rpc-url <rpcUrl> --ffi -vvvv
```

This logs predicted addresses up front (verify them — the factory, dispatcher, and RoutePolicy proxy
should match across chains), then deploys each contract via CREATE2 (idempotent — already-deployed
contracts are skipped). With `transferRoles=true` it transfers the `AdminWithdrawManager` roles and
the `RoutePolicy` proxy ownership to the chain-local multisig.

After this step the `RoutePolicy` is deployed but **inactive** — its root is still the genesis
`bytes32(0)`, so non-user executors can't do anything yet (the user escape still works). Activation
is the next step.

### 3. Activate the policy (per chain, by the multisig)

Build the chain's route merkle tree off-chain, then rotate the proxy to that root:

```bash
forge script script/counterfactual/RotateRoutePolicyRoot.s.sol:RotateRoutePolicyRoot \
  --sig "run(address,bytes32)" <routePolicyProxy> <realRoot> \
  --rpc-url <rpcUrl> --broadcast --verify -vvvv
```

`upgradeToAndCall` is owner-gated. If the proxy owner is an EOA you control, the script performs the
upgrade directly. If the owner is a multisig (production), run without `--broadcast` to deploy the
new implementation and log the `upgradeToAndCall(newImpl, "")` calldata, then submit that call from
the multisig (e.g. as a Safe transaction). The proxy address does not change — clones are unaffected.

To change the route set later, run `RotateRoutePolicyRoot` again with the new root.

### 4. Verify

```bash
source .env
FOUNDRY_PROFILE=counterfactual forge script \
  script/counterfactual/CheckCounterfactualDeployments.s.sol:CheckCounterfactualDeployments \
  --rpc-url $NODE_URL_1 --ffi -vvvv
```

Forks every configured chain and checks bytecode presence, the `WithdrawImplementation.admin ==
AdminWithdrawManager` wiring, the `RoutePolicy` proxy (predicted address has code, `activeRoot`
responds, owner review), and the bridge impls' constructor params. `[PASS]`/`[FAIL]` are
auto-checks; `[REVIEW]` items (signer, owners, un-activated roots) require human eyes.

## Maintaining cross-chain consistency — checklist

When adding a new source chain or changing the deploy flow, preserve all of these:

- [ ] Same `MNEMONIC` (→ same deployer EOA) used for genesis on every chain.
- [ ] Same `deploySalt` for the factory, dispatcher, and RoutePolicy. This is the optional top-level
      key in `config.toml` (defaults to `bytes32(0)`). Because it's a single global key in the one
      shared config file, it is uniform across chains by construction — do not move it into the
      per-chain `[chainId.address]` sections, which would let it diverge.
- [ ] `CounterfactualDepositFactory` and `CounterfactualDeposit` have **no** constructor args (don't
      add any — it would make clone addresses chain-specific).
- [ ] `RoutePolicy` genesis impl uses `GENESIS_ROUTE_POLICY_ROOT` (`bytes32(0)`), never a real root.
- [ ] `RoutePolicy` proxy genesis owner is the **deployer EOA**, never the chain-local multisig.
- [ ] Real roots and the multisig owner are applied **after** genesis (rotation + ownership transfer),
      which are address-neutral.
- [ ] `signer` is a single global top-level key in `config.toml` (like `deploySalt`), so it is uniform
      across chains by construction — keeping `AdminWithdrawManager` and, transitively,
      `WithdrawImplementation` uniform. Do not move it into the per-chain `[chainId.address]` sections,
      which would let it diverge.
- [ ] Run `CheckCounterfactualDeployments` after deploying a new chain and confirm the factory,
      dispatcher, and RoutePolicy proxy addresses match the other chains.
