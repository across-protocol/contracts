# USDFree (Interfaces)

`Interfaces.sol` is the canonical design surface for this folder.

This iteration uses a generic `(enum, data)` pattern for requirement modifiers, requirements, and continuation payloads.

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
  - Supports generic requirement-modifier dispatch (`Offchain` implemented; `DutchOnchain` reserved in enum).
  - Applies generic requirement changes via `RequirementChange[]`.
  - Executes submitter actions by type (internal multicall-like `ExecutorCall[]` now, `Weiroll` reserved).
  - Decodes typed step user payload (`TypedData userData`) with versioned variants.
  - Uses explicit forwarding amounts with submitter override and user fallback.
  - Supports both:
    - `UserRequirementsAndAction`: approval-based ERC20 + native `msg.value` to `IUserActionExecutor`.
    - `UserRequirementsAndSend`: push-based ERC20/native directly to recipient.

- `OrderStore.sol`:
  - Open `handle()` / `handleAtomic()` / `fill()` / `refundByUser()` / `refundByAdmin()` entrypoints.
  - Uses typed continuation wrapper (no length-based hash checks).
  - Supports transparent, hash-obfuscated, and explicit `StepAndNext` continuation forms for fill path.
  - Stores per-step refund config (`refundRecipient`, `reverseDeadline`) when persisting orders.

## Type Pattern

Most extensibility surfaces are encoded as `(typ, data)`:

- `TypedData { uint8 typ; bytes data }`
- `RequirementModifierAction { AuctionType typ; bytes data }`
- `SubmitterActions { SubmitterActionType typ; bytes data }`
- `ForwardingAmounts { uint256 erc20Amount; uint256 nativeAmount }`
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

`SubmitterData.extraErc20Funding` is ERC20-only; submitter native funding is `msg.value` surplus above user native funding.

## Requirement Modifier Flow

For `GenericStepType.AuctionSubmitterUser`:

- Step `userData`:
  - `TypedData{ typ: RequirementsAndActionV1, data: abi.encode(UserRequirementsAndAction) }`, or
  - `TypedData{ typ: RequirementsAndSendV1, data: abi.encode(UserRequirementsAndSend) }`
- Step `parts`:
  1. `RequirementModifierAction`
- Submitter parts:
  1. `AuctionResolution` (contains `RequirementChange[]` + signature)
  2. `SubmitterActions`
  3. optional `ForwardingAmounts`

For `GenericStepType.SubmitterUser`, submitter parts are:

1. `SubmitterActions`
2. optional `ForwardingAmounts`

For `GenericStepType.User`, submitter parts are always empty and forwarding comes from user payload defaults.

`RequirementChange` supports:

- `reqId` routing:
  - `0`: token requirement
  - `1..N`: static requirement index replace
  - `254`: user action replace
  - `255`: append static requirement

Token requirement changes enforce user-improvement constraints (same token, non-decreasing amount).

Token requirement type is `MinAmount` only. Requirement evaluation is performed against explicit forwarded amounts (ERC20/native) instead of full executor balances.

## Continuations

`ContinuationType`:

- `GenericSteps`: `data = abi.encode(GenericStep[])`
- `StepAndNextHash`: `data = abi.encode(bytes32)` and first submitter part provides matching deobfuscation
- `StepAndNextData`: `data = abi.encode(StepAndNext)`

`StepAndNextData` specifically addresses atomic execution when only deobfuscated current step payload is available.

## Token Handover

`OrderGateway` and `OrderStore` pull ERC20s into themselves first, then push ERC20s to `Executor` using balance-delta handoff patterns. This keeps token movement explicit and robust for fee-on-transfer tokens.
