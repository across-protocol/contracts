# SpokePoolV5 ↔ Across V5 Gateway — design spec

Status: **implemented** (compiles; tests pending). Integration between `SpokePoolV5`
(this repo, `contracts/`) and the Across V5 `Gateway`/`Executor` (sibling repo,
`contracts-v5/`).

Implemented in:

- `contracts/contracts/spoke-pools/interfaces/IGateway.sol` (new)
- `contracts/contracts/spoke-pools/SpokePool.sol` (3 additive `virtual` seams: `_fillRelayV3`,
  `_transferTokensToRecipient`, and a new `_pullDepositFunds` extracted from `_depositV3`)
- `contracts/contracts/spoke-pools/SpokePoolV5.sol` (`depositV5`, `fillV5`, gate + fund-source overrides)
- `contracts-v5/src/planners/AcrossFillPlanner.sol` (new, stateless `IPlanner`)

## 1. Goal & the guarantee

- **Origin:** `depositV5` pulls the input token from the **Gateway submitter**
  (ERC-20 only), tags the deposit as "V5", and binds it to a specific **destination
  path** the user has already constructed.
- **Destination:** a V5-tagged deposit can be settled **only** by `fillV5` while
  executing inside the canonical Gateway, **and only within the exact destination
  path the deposit named**. Every other path — direct `fillRelay`, `fillV3Relay`,
  `fillRelayWithUpdatedDeposit`, and **slow fills** — reverts.
- The guarantee holds iff the destination chain runs `SpokePoolV5` pointing at the
  canonical `gateway`. A plain `SpokePool` treats the header as opaque bytes.

Both origin deposit and destination fill are executed as raw `CALL`s by the
**Executor**. The origin `CALL` is emitted directly from the path tape; the
destination `CALL` is materialized by a stateless, read-only **`AcrossFillPlanner`**
(`PLAN_FROM_PLANNER`) that merges the path-committed `relayData` with the
submitter's JIT repayment params. There is **no `AcrossFunder`** and **no
fund-custodying fill adapter** in this design.

All address-shaped params on `depositV5`/`fillV5` are `bytes32`, matching the base
V3 API (SVM-compatible).

## 2. The V5 marker & message

- `bytes32 public constant V5_DEPOSIT_HEADER = keccak256("AcrossV5Deposit");`
- Message layout: `message = abi.encodePacked(V5_DEPOSIT_HEADER, destPathId)` — 64
  bytes. The first word is the gate marker; the second is the **destination
  `pathId`** the deposit is bound to.
- `encodePacked` so a non-V5 `abi.decode` is never accidentally shifted; the marker
  is just the first 32-byte word.
- Detection: `_isV5(message) = message.length >= 32 && bytes32(message[0:32]) == V5_DEPOSIT_HEADER`.
- The message is **control data only** — it is never delivered to the recipient
  (the V5 fill path skips `handleV3AcrossMessage`). It carries no application
  payload; destination routing lives in the bound path, not the message.
- The message is committed in `getV3RelayHash` and (as a hash) in
  `FundsDeposited`/`FilledRelay`, so the **origin deposit binds the destination's
  fill rules**.

## 3. Binding & the circular dependency (core of the design)

We want the deposit bound to a specific destination `pathId` so that the fill can
only happen with the user's intended onward routing (recipient may be the Executor
for swaps/transfers). Naively committing `destPathId` in the message is circular:

```
depositMessage   ⊇ destPathId
destPathId       = keccak256(chainId, salt, executor, keccak256(destPath.message))
destPath.message ⊇ fillV5 call ⊇ relayData ⊇ relayData.message ( == depositMessage )
```

**Fix — reconstruct, don't commit.** Any `relayData` field that depends on
`destPathId` is _reconstructed_ inside `fillV5` from `gateway.currentPathId()`
instead of being committed in the destination path tape. Concretely, the **message**
is rebuilt at fill time:

```
fillV5(relayDataSansMessage, repaymentChainId):     // committed in destPath.message
    message  = abi.encodePacked(V5_DEPOSIT_HEADER, gateway.currentPathId())   // reconstructed
    relayData = relayDataSansMessage + { message }
    relayHash = getV3RelayHash(relayData)
    ...
```

Now `destPath.message` contains no `destPathId`-derived field, so `destPathId` is
well-defined and the user can compute it before depositing. **Cycle broken.**

**Binding is enforced by Across repayment, for free.** To claim the origin funds the
fill's reconstructed `relayHash` must equal the real deposit's. That requires
`HEADER ‖ currentPathId() == HEADER ‖ destPathId`, i.e. the submitter is executing
the exact path the deposit named. A different path → different `relayHash` → "fills"
a non-existent deposit → no repayment, and the real deposit stays untouched and
refundable. No explicit `require` needed.

> **`depositId` must also be `destPathId`-independent**, or it re-creates the cycle
> (it rides in `relayData`). See §4.

## 4. `depositId`, submitters, and reconstruction

`depositId = keccak256(submitter, depositor, depositNonce)` where `submitter` is the
**origin** Gateway submitter. This is `destPathId`-independent (no cycle) and
namespaced by submitter (anti-grief: nobody else can pre-register a colliding id).

**Submitter model: distinct origin/destination submitters, origin pinned at build.**

- The **origin path** pins its submitter with a `SUBMITTER_REQ`, so `depositV5`'s
  `currentSubmitter()` is guaranteed to equal a known address (the user funding
  their own deposit, or a designated relayer).
- Because the origin submitter is known when the intent is built, `depositId` is
  known too and is **committed directly** in the destination `relayData` — no
  reconstruction, no JIT, **raw `CALL` preserved**.
- The **destination submitter is free/competitive** — it funds the fill output and
  is repaid. Origin and destination submitters may differ.

(If the origin side ever needs to be open to arbitrary relayers, `depositId` can't
be committed; the origin submitter would then be passed JIT and `depositId` computed
in the `AcrossFillPlanner` at fill time. Not in scope.)

## 5. Origin: `depositV5`

Invoked by the Executor via raw `CALL`, after a `SUBMITTER_REQ` that pins the origin
submitter.

1. `submitter = gateway.currentSubmitter()` (== the pinned address).
2. **ERC-20 only:** `require(msg.value == 0)`.
3. Pull funds from the **submitter**, not `msg.sender`:
   `inputToken.safeTransferFrom(submitter, address(this), inputAmount)`.
   (Submitter approves `SpokePoolV5` directly.)
4. `depositId = uint256(keccak256(abi.encodePacked(submitter, depositor, depositNonce)))`.
5. `message = abi.encodePacked(V5_DEPOSIT_HEADER, destPathId)` (`destPathId` is a
   `depositV5` argument).
6. Run base validation + emit `FundsDeposited`.

Funds path: **submitter → SpokePoolV5** directly (no funding→executor→adapter hops).

## 6. Destination: `fillV5` + the gate

Signature: `fillV5(V3RelayData relayData, uint256 repaymentChainId, bytes32 repaymentAddress)`.

Invoked via a `PLAN_FROM_PLANNER` command that staticcalls `AcrossFillPlanner` with
the **path-committed `relayData`** and the **submitter's JIT** `(repaymentChainId,
repaymentAddress)`; the planner returns a single `CALL → fillV5(...)` that the
Executor executes. The committed `relayData` carries an **empty `message`** (so the
destination tape stays `destPathId`-independent — see §3).

`fillV5`:

1. `submitter = gateway.currentSubmitter(); require(submitter != 0)`.
2. **Overwrite** `relayData.message = abi.encodePacked(V5_DEPOSIT_HEADER, gateway.currentPathId())`
   (`fillV5` is the source of truth for the message, regardless of what the planner
   emitted); compute `relayHash`.
3. Pull `outputAmount` of `outputToken` from the **destination submitter**
   (`safeTransferFrom(submitter, …)`) — mirrors `depositV5`.
4. Deliver to `relayData.recipient`. **Skip** `handleV3AcrossMessage` (message is
   control data) → recipient may be an **EOA** for direct delivery, or the
   **Executor** when the tape routes onward (swap/transfer).
5. Repay the destination submitter: `repaymentChainId` / `repaymentAddress` come from
   the submitter's JIT input (their choice of where to be repaid).
6. Record `FilledRelay` / `fillStatuses[relayHash] = Filled`.

The gate that blocks every _other_ fill path lives in the common internal
`_fillRelayV3` (`SpokePool.sol:1571`) — the chokepoint for fast fills, all `fill*`
variants, and slow fills:

```
_fillRelayV3(execParams, relayer, isSlowFill):
    if _isV5(execParams.relay.message):
        require(!isSlowFill, "V5SlowFillNotAllowed")
        require(gateway.currentSubmitter() != 0, "V5RequiresGateway")
    ...
```

- Direct `fillRelay`/`fillV3Relay` outside the Gateway → `currentSubmitter()==0` →
  revert. Slow fill of a V5 deposit → revert. `fillV5` inside the Gateway → passes.

## 7. Required base `SpokePool` changes (audited-surface cost)

Minimal, additive, behavior-preserving for non-V5 deposits; exact seams are an
implementation choice:

1. `_fillRelayV3` → `virtual` (header gate + slow-fill block).
2. A `virtual` seam for the **deposit fund pull** (default = current
   WETH/ERC-20-from-`msg.sender`) so V5 pulls ERC-20 from the submitter.
3. A `virtual` seam for the **fill fund source** (default `msg.sender`) so V5 pulls
   the output from the submitter.
4. A `virtual` seam to **gate the message handler** (default `message.length > 0`)
   so V5 skips `handleV3AcrossMessage`.

No base storage-layout changes; no logic changes on existing paths.
`SpokePoolV5.gateway` is **`immutable`**, set in the constructor (matches
`wrappedNativeToken`; safe under UUPS).

## 8. New interface: `IGateway` (this repo)

`SpokePoolV5.sol` imports `./interfaces/IGateway.sol`, which **does not exist yet**
(no `spoke-pools/interfaces/` dir) — the scaffold currently won't compile. Create it
mirroring `contracts-v5/src/interfaces/IGateway.sol`:

```solidity
function currentSubmitter() external view returns (address);
function currentPathId() external view returns (bytes32);
```

## 9. Executor wiring (`contracts-v5`)

Executor command tapes — no funder, no fund-custodying adapter. The destination
adds one new **stateless `IPlanner`** (`AcrossFillPlanner`, in `contracts-v5`) that
merges committed `relayData` + JIT repayment into a `fillV5` CALL:

```
Origin   Gateway.execute → Executor:
           SUBMITTER_REQ(pinnedOriginSubmitter)     // pins the submitter in depositId
           CALL SpokePoolV5.depositV5(..., destPathId, depositNonce)

Destination Gateway.execute → Executor:
           [SUBMITTER_REQ for the auction winner, if any]
           [BALANCE_REQ / TIMESTAMP_REQ ...]
           PLAN_FROM_PLANNER | FLAG_READS_JIT
               committed = (AcrossFillPlanner, spokePool, relayData)   // relayData.message empty
               jit       = (repaymentChainId, repaymentAddress)
             → materializes:  CALL SpokePoolV5.fillV5(relayData, repaymentChainId, repaymentAddress)
           [onward routing commands if recipient == Executor]
```

`AcrossFillPlanner.plan(input, jitData)` is read-only (staticcall): it decodes the
committed `(spokePool, relayData)` and the JIT `(repaymentChainId, repaymentAddress)`,
and returns a one-command tape `[CALL → fillV5(relayData, repaymentChainId, repaymentAddress)]`.
It holds no funds and verifies no signature — binding is enforced by `fillV5`'s
`relayHash` reconstruction (§3), not the planner.

**Ordering win:** the fill is an execution command placed _after_ requirements, so
it only runs for an authorized submitter — vs. the funder model where the fill ran
during funding and rolled back on a later requirement failure.

## 10. What this design removes

- **`AcrossFunder`** and any fund-custodying fill adapter — the fill is a raw `CALL`
  materialized by the read-only `AcrossFillPlanner`.
- **The witness-in-message mechanism** — no funder does `abi.decode(message,(bytes32))`,
  so the header breaks no decoder and `WitnessMismatch` is gone. Binding is the
  reconstructed-`relayHash` match (§3).
- **`nextStepId` crosschain** — gone; destination routing is in the bound path.

## 11. Trust model & invariants

- `SpokePoolV5` trusts exactly **one** `gateway`; a fake gateway can't forge the
  canonical one's transient `currentSubmitter()`/`currentPathId()`.
- `Gateway.execute` sets the submitter/path context before calling the Executor and
  clears it after; a `CALL` from the Executor stays in that frame, so the context is
  live throughout deposit/fill.
- `nonReentrant` unaffected: `Gateway → Executor → SpokePoolV5` is the first
  SpokePool entry in the tx.
- **Invariant:** a V5 deposit is settled _only_ by `fillV5`, _only_ inside the
  canonical Gateway, _only_ within the destination path it named, _only_ by a
  submitter (origin pinned, destination free).

## 12. Edge cases & open implementation details

- **Repayment is submitter-chosen:** `repaymentChainId`/`repaymentAddress` are
  passed JIT through the `AcrossFillPlanner` (not committed), so destination
  submitters pick where they're repaid. They aren't part of `relayData`/`relayHash`,
  so this doesn't touch binding.
- **Self-griefing only:** anyone can hand-tag a normal deposit with the header → it
  becomes Gateway-only-fillable; unused, it expires and refunds.
- **Origin and destination are different deployments** — both must be `SpokePoolV5`.
- **`V5_DEPOSIT_HEADER` is duplicated across repos** — single documented source of
  truth for the literal.
- **`depositNonce`** is a `depositV5` argument and is committed (via `depositId`) in
  the destination `relayData`.
- **`AcrossFillPlanner` is a new `contracts-v5` contract** — stateless `IPlanner`,
  staticcall-only; the existing `SpokePoolV5` stub's `address` params must be
  switched to `bytes32` to match the base V3 API.
- **WETH output on fill** — not applicable while V5 is ERC-20-only.

## Decisions (locked)

1. `depositId = keccak256(submitter, depositor, depositNonce)` — committed on the
   destination; origin submitter pinned via `SUBMITTER_REQ`.
2. Header layout: `encodePacked`.
3. `gateway` reference is `immutable`.
4. Slow fills blocked for V5 deposits.
5. Deposit pulls from the submitter, ERC-20 only.
6. Fill is driven by the Executor (no `AcrossFunder`).
7. `fillV5` pulls output from the (destination) submitter.
8. Message = `HEADER ‖ destPathId`; control data only, handler skipped, recipient
   may be an EOA.
9. Fill executed as a raw `CALL` (no fund-custodying adapter), materialized by a
   read-only `AcrossFillPlanner` (`PLAN_FROM_PLANNER`) that merges committed
   `relayData` + JIT `(repaymentChainId, repaymentAddress)`. `fillV5` reconstructs
   `message` from `currentPathId()` to break the cycle.
10. Distinct origin/destination submitters; origin known at build time.
11. `depositV5`/`fillV5` use `bytes32` address-shaped params (match base V3 API).
