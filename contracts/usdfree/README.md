# USDFree

USDFree is a mechanism-agnostic cross-chain order execution model intended to unify CCTP, OFT, and Across-style flows behind one intent format.

This folder currently defines interface and data-model contracts only (`Interfaces.sol`).

## Current Interface Surface

### Order submission

`OrderGateway` exposes:

- `submit(Order, SubmitterProvided)` for single-path orders.
- `submitMerkle(MerkleOrder, SelectedPath, SubmitterProvided)` for multi-path orders with submitter-selected Merkle proof.

### Step execution

`Executor.execute(...)` executes exactly one `ExecutionStep` using:

- `SubmitterData.actions` for submitter-provided actions.
- `AuctionRuntime` for per-route authorization payloads.
- `TokenHandoff` to control how tokens are handed to `IUserActionExecutor` (`Push`, `ApprovePull`, `Permit2Pull`).

`IUserActionExecutor.execute(...)` receives token + amount + current action payload and may propagate `nextSteps`.

### Destination handling

`OrderStore` exposes:

- `handle(...)` to store a bridged order.
- `handleAtomic(...)` for immediate fill after bridge handling.
- `fill(...)` for permissionless or submitter-driven fills of stored orders.

## Core Data Model

### Order and paths

- `Order`: `{ salt, steps, auctionSettings }`
- `MerkleOrder`: `{ salt, pathRoot, pathCount }`
- `SelectedPath`: `{ steps, auctionSettings, proof }`

### Step requirements

Each `ExecutionStep` includes:

- `tokenReq` (required token/amount shape, encoded bytes)
- `submitterReq` (optional submitter constraint)
- `deadlineReq` (optional deadline)
- `otherStaticReqs` (executor-specific extra checks)
- `hashOrUserAction` (obfuscated hash or clear action)
- `refundRecipient`
- `tokenHandoff`

### Auctions

- User policy is encoded in `UserAuctionSettings` and per-route `AuctionRoute`.
- Runtime payload is `AuctionRuntime.routeAuthorizations[]`.
- `IAuctionModule.resolve(...)` verifies route authorization and returns `ProposedChangeSet`.

## Known Issues / Open Design Decisions

These should be resolved before production implementation.

1. Untyped `bytes` requirements are underspecified.

   - `ExecutionStep.tokenReq`, `submitterReq`, `deadlineReq`, and `hashOrUserAction` do not define canonical encoding/versioning.
   - Risk: incompatible decoders across modules/chains and malformed payload ambiguity.

2. Auction authorization is not fully route-bound in the signed payload.

   - `RouteAuthorization.routeIndex` is outside `AuctionAuthorization`.
   - If modules/routes share validation domains, payload reuse/substitution risk exists unless executors add strict binding checks.

3. `stepBitmap` format is unspecified.

   - `AuctionRoute.stepBitmap` does not define bit ordering, max step index behavior, or required bitmap length relative to `steps.length`.
   - Risk: inconsistent route invocation and bypass via decoder mismatch.

4. `IAuctionModule.resolve` is `view` only.

   - This forbids stateful on-chain auction settlement inside module resolution.
   - If stateful auctions are required, interface mutability likely needs to change.

5. Funding payload shape is duplicated and unclear.

   - `SubmitterProvided.funding` (`bytes`) overlaps with `SubmitterData.extraFunding` (`TokenAmount[]`).
   - Risk: conflicting source-of-truth and implementation drift.

6. Token handoff safety rules are not part of the interface contract.

   - `TokenHandoff.data` is free-form and approval lifecycle (exact spender, amount caps, revocation) is not standardized.
   - Risk: stale allowances or inconsistent Permit2 integration.

7. Replay and domain separation requirements are implied, not explicit.

   - `AuctionAuthorization` includes `orderId`, `stepIndex`, `targetChainId`, and `targetContract`, but required source domain and nonce semantics are not specified.
   - Risk: cross-domain replay if implementations differ on hashing/domain separator.

8. Documentation drift existed and must be kept aligned.
   - Previous docs referenced methods and flow that do not exist in `Interfaces.sol` (for example `submitWithAuction()` and legacy auction-authority flow).

## Recommended Next Steps

1. Replace ambiguous `bytes` fields with typed structs where possible.
2. Define canonical EIP-712 types for order + route authorization, including `routeIndex` and explicit domain fields.
3. Specify `stepBitmap` semantics in code comments and enforce bitmap validation in executor.
4. Decide whether auction modules must be stateless (`view`) or allow state updates.
5. Add invariant tests for route invocation, authorization replay resistance, and token handoff approval hygiene.
