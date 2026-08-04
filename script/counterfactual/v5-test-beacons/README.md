# V5 test beacons

A **separate** counterfactual beacon stack on Base and Arbitrum, deployed under its own CREATE2 salt so the
production beacons on those chains are never touched. Its purpose is to let the Across V5 counterfactual
vertical run against a real `CounterfactualBeacon` — one that carries the getters V5 resolves — instead of the
V5 repo's mutable `MockBeacon`.

Everything here mirrors [`script/counterfactual/`](../) one level up. Same contracts, same CREATE2 mechanics,
same idempotent/self-healing deploy. Only three things differ:

|              | production                         | here                                                |
| ------------ | ---------------------------------- | --------------------------------------------------- |
| config file  | [`../config.toml`](../config.toml) | [`config.toml`](config.toml) — Base + Arbitrum only |
| CREATE2 salt | `[0.bytes32] deploySalt` there     | `[0.bytes32] deploySalt` here, overridable per run  |
| factory      | its own script                     | step 6 of `DeployV5TestBeacon` (it is beacon-bound) |

## What the beacon publishes

`CounterfactualBeacon` bakes its config as `public immutable` getters, and V5 addresses them **by getter
selector**: a `CounterfactualRoute` / `Template` commits `bytes4` selectors (`inputTokenGetter`,
`executorGetter`, `bridgeEndpointGetter`, `swapOutputTokenGetter`, `maxExecutionFeeGetter`,
`cctpMaxFeeBpsGetter`) that V5's `BeaconLib` resolves by staticcall. The getter set now covers both verticals —
see `ICounterfactualBeacon` for the V5 additions (`gateway`, `usdtOft`, the five executors, the remaining
per-`(token, bridge)` caps, the per-token `stablePrice`s and the `stablePrice(address)` dispatcher).

Every key in `config.toml` is named after the getter it feeds. Renaming a key without renaming the getter
silently orphans it.

## Deploy order

The one non-obvious constraint: **the impl bakes `destinationExecutor` as an immutable, while V5's
`CounterfactualDestinationExecutor` is constructor-bound to the beacon proxy.** The cycle only resolves in one
direction — the proxy address is a pure function of the salt, the bootstrap's creation code and the deployer,
so it is known before any impl exists:

```sh
source .env   # MNEMONIC, NODE_URL_8453, NODE_URL_42161, ETHERSCAN_API_KEY

# 1. Predict. Offline; prints the proxy address the V5 executors must be bound to.
FOUNDRY_PROFILE=counterfactual forge script \
  script/counterfactual/v5-test-beacons/PredictV5TestBeacon.s.sol:PredictV5TestBeacon \
  --sig "run()" --rpc-url base

# 2. Deploy the V5 stack from the V5 repo against that proxy address, then paste `gateway` and the five
#    executor addresses into config.toml. (Skippable on a first pass — see "Filling in later" below.)

# 3. Beacon implementation (plain CREATE, per-chain address). Review the logged config dump: it is immutable.
FOUNDRY_PROFILE=counterfactual forge script \
  script/counterfactual/v5-test-beacons/DeployV5TestBeaconImpl.s.sol:DeployV5TestBeaconImpl \
  --rpc-url base --broadcast --verify

# 4. Beacon stack: bootstrap, proxy, upgrade-to-impl, dispatcher, setImplementation, factory.
#    --sig is REQUIRED (four `run` overloads). --slow: the run is multi-tx and later txs get dropped
#    against an RPC whose nonce view lags.
FOUNDRY_PROFILE=counterfactual forge script \
  script/counterfactual/v5-test-beacons/DeployV5TestBeacon.s.sol:DeployV5TestBeacon \
  --sig "run()" --rpc-url base --broadcast --slow --verify
```

Then repeat 3–4 with `--rpc-url arbitrum`. Step 4 reads step 3's broadcast (`run-latest.json`) for this chain,
so step 3 must have been broadcast, not just simulated.

Add `--sig "run(bool)" true` to step 4 to also `transferOwnership` to the config's `ownerAndDirectWithdrawer`
(Ownable2Step — the new owner accepts out of band). Both deploy steps are idempotent: an already-deployed
contract is skipped, and a run interrupted between steps self-heals on the next invocation.

### Filling in later

Values left unset bake as zero, and zero means different things by type — deliberately:

- an **address** getter reads `address(0)`, which callers turn into `RouteNotConfigured` — the route fails closed;
- a **`*MaxExecutionFee`** reads `0`, a _valid_ fee-free route: any non-zero quoted fee reverts `ExecutionFeeAboveCap`;
- a **`*StablePrice`** reads `0`, marking the token unpriced (volatile), which **skips** V5's stable swap floor
  for every pair touching it. `wethStablePrice` is set this way on purpose.

So the beacon can be deployed before the V5 executors exist; those routes simply fail closed. Because the
values are immutable, filling them in later is a **new impl plus a UUPS upgrade of the proxy**, done by the
owner: deploy step 3 again, then `CounterfactualBeacon(proxy).upgradeToAndCall(newImpl, "")`. The proxy address
never changes, so nothing committed against it has to move.

## Salt

`[0.bytes32] deploySalt` in this folder's `config.toml`, or a non-zero `bytes32` argument for a one-off:
`--sig "run(bytes32)" 0x…` / `--sig "run(bytes32,bool)" 0x… true`. It is deliberately not the production salt —
that separation is what makes these a distinct deployment.

Bumping it mints a **new** proxy, dispatcher and factory: a fresh test beacon, not an upgrade. Anything bound
to the old proxy (V5 routes, the destination executor) must be re-pointed, so prefer a UUPS upgrade of the
implementation when all you need is different config.

## What is redeployed, and what is reused

`CounterfactualDeposit.BEACON` and `CounterfactualDepositFactory.BEACON` are **immutables**, and
`setImplementation` rejects any target whose `BEACON()` does not point back at the beacon (`WrongBeacon`). A
beacon at a new proxy address therefore needs its own dispatcher and factory — both deployed by
`DeployV5TestBeacon`.

The leaf implementations (`CounterfactualDepositSpokePool`, `…CCTP`, `…OFT`, `…VanillaCCTP`) hold **no** beacon
immutable: they read config from the proxy's ERC-1967 beacon slot at runtime, and a route leaf names the
implementation address directly. The **existing production deployments are reused as-is** — nothing to
redeploy, nothing to register.

## Where each value comes from

- **Overrides.** `spokePool`, the tokens, `wrappedNativeToken`, `nativeToken`, `cctpSrcPeriphery`,
  `cctpTokenMessenger`, `oftSrcPeriphery`, `cctpSourceDomain` and `oftSrcEid` are resolved from
  `constants.json` + `broadcast/deployed-addresses.json` by the shared resolvers in
  [`../CounterfactualConfig.sol`](../CounterfactualConfig.sol). A same-named key in `[<chainId>.address]` (or
  `[<chainId>.uint]`) **wins**, and every substitution is logged as `override <key>: <new> (resolved: <old>)`.
  This exists for `spokePool`: V5 routes must hit the V5-enabled SpokePool proxies, which are not the canonical
  ones in `deployed-addresses.json`.
- **V5-only.** `gateway`, `usdtOft`, the five executors, all `*MaxExecutionFee` caps, `usdcCctpMaxFeeBps` and
  the `*StablePrice`s have no resolver — they come from `config.toml` or they are zero.

Two production rules are deliberately relaxed here, because the V5 surface is still moving: there is no
`[N.bool]` declared-support cross-check, and a zero fee cap is permitted instead of fatal. The two invariants
that remain fatal are a zero `signer` and a zero `spokePool` (baking either would brick every route), plus the
`nativeToken == sentinel ⇒ wrappedNativeToken != 0` pairing.

## Note on the production beacons

`CounterfactualChainConfig` gained the V5 fields, but the production builder (`_buildChainConfig`) leaves them
at zero — no production chain has V5 addresses to bake yet. A production beacon impl deployed from this branch
would therefore publish `gateway`/the executors as `address(0)` and the V5 caps and prices as `0`. Fail-closed
for the addresses, "fee-free"/"unpriced" for the numbers, but it means a production impl built here is **not**
V5-configured.
