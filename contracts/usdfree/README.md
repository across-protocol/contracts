# USDFree (Interfaces)

`Interfaces.sol` is the canonical design surface for this folder.

This iteration uses a generic `(enum, data)` pattern for auction, requirements, transfer, and continuation payloads.

## Contracts

- `OrderGateway.sol` (UUPS upgradeable):

  - Single `submit()` entrypoint for approval + gasless flows.
  - Computes `orderId` from domain separation + salt + encoded order.
  - Enforces one-time `orderId` usage.
  - Verifies Merkle route and forwards funding to `Executor`.

- `Executor.sol`:

  - Executes one `StepAndNext` chunk.
  - Uses modular sequence handlers:
    - `_executeAuctionSubmitterUser`
    - `_executeSubmitterUser`
    - `_executeUser`
  - Supports generic auction dispatch (`Offchain` implemented; `DutchOnchain` reserved in enum).
  - Applies generic auction changes via `RequirementChange[]`.
  - Executes submitter actions by type (internal multicall-like `ExecutorCall[]` now, `Weiroll` reserved).

- `OrderStore.sol`:
  - Open `handle()` / `handleAtomic()` / `fill()` entrypoints.
  - Uses typed continuation wrapper (no length-based hash checks).
  - Supports transparent, hash-obfuscated, and explicit `StepAndNext` continuation forms.

## Type Pattern

Most extensibility surfaces are encoded as `(typ, data)`:

- `TypedData { uint8 typ; bytes data }`
- `AuctionAction { AuctionType typ; bytes data }`
- `SubmitterActions { SubmitterActionType typ; bytes data }`
- `Continuation { ContinuationType typ; bytes data }`

This keeps interfaces stable while allowing new variants to be added in executor logic.

## Funding (`OrderGateway.submit`)

`funding` is encoded as:

```solidity
abi.encode(OrderGateway.Funding({ typ: FundingType, data: ... }))
```

Supported modes:

1. `Approval`
2. `Permit` (EIP-2612 + separate order witness signature)
3. `Permit2` (witness bound to `orderId`)
4. `Authorization` (ERC-3009, nonce = `orderId`)
5. `Native`

`SubmitterData.extraFunding` also supports native submitter funding via `TokenAmount{token: address(0), amount}`.

## Auction Flow

For `GenericStepType.AuctionSubmitterUser`:

- User parts:
  1. `AuctionAction`
  2. `UserRequirementsAndAction`
- Submitter parts:
  1. `AuctionResolution` (contains `RequirementChange[]` + signature)
  2. `SubmitterActions`

`RequirementChange` supports:

- `stepOffset`: currently `0` implemented (current step), future offsets reserved.
- `reqId` routing:
  - `0`: token requirement
  - `1..N`: static requirement index replace
  - `254`: user action replace
  - `255`: append static requirement

Token requirement changes enforce user-improvement constraints (same token, non-decreasing amount, no strict->min downgrade).

## Continuations

`ContinuationType`:

- `GenericSteps`: `data = abi.encode(GenericStep[])`
- `StepAndNextHash`: `data = abi.encode(bytes32)` and first submitter part provides matching deobfuscation
- `StepAndNextData`: `data = abi.encode(StepAndNext)`

`StepAndNextData` specifically addresses atomic execution when only deobfuscated current step payload is available.

## Token Handover

`OrderGateway` and `OrderStore` use balance-delta handoff patterns when moving ERC20s to `Executor`, so the executor uses actual received amounts (more robust for fee-on-transfer tokens).
