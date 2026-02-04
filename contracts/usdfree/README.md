# USDFree

A mechanism-agnostic cross-chain order system that unifies CCTP, OFT, and Across bridge flows into a single architecture.

## Goals

- Bridge tokens cross-chain regardless of underlying mechanism
- Single upgradeable entry point (no re-approvals needed)
- Support gasless flows and sponsorship
- Enable chained cross-chain operations (src → A → B → dst)
- Execute arbitrary user actions after token delivery

## Architecture

```
Source Chain:
User → OrderGateway → Executor → IUserActionExecutor
                                        ↓
                            [Bridge Message with nextSteps]
                                        ↓
                                Destination Chain:
BridgeHandler → OrderStore → Executor → IUserActionExecutor
```

### Components

**OrderGateway** - Entry point for order submissions

- `submit()` - Submit order with funding
- `submitWithAuction()` - Submit with auction-based price improvement

**Executor** - Executes a single step

- Runs submitter actions (swaps, etc.)
- Checks requirements after submitter actions complete
- Calls IUserActionExecutor with token, amount, params, and remaining steps

**IUserActionExecutor** - Final action interface

- Receives tokens and executes user-specified action
- Propagates `nextSteps` to continue cross-chain execution

**OrderStore** - Destination-side order management

- `handle()` - Receive tokens from bridge, store for filling
- `handleAtomic()` - Receive and fill in one transaction
- `fill()` - Fill a stored order

## Key Data Structures

### ExecutionStep

Defines requirements and action for one step in the order:

```solidity
struct ExecutionStep {
  bytes tokenReq; // (token, amount) - amount=0 means no enforcement
  bytes submitterReq; // Required submitter address (empty = anyone)
  bytes deadlineReq; // Deadline timestamp (empty = none)
  bytes[] otherStaticReqs; // Additional requirements (Executor-specific)
  bytes hashOrUserAction; // User action or hash for obfuscation
  address refundRecipient; // Where to send tokens if deadline passes
}
```

### Order

What the user signs:

```solidity
struct Order {
  bytes32 salt;
  ExecutionStep[] steps;
}
```

### SubmitterData

What the submitter provides to execute a step:

```solidity
struct SubmitterData {
  TokenAmount[] extraFunding; // Additional tokens from submitter
  bytes actions; // Encoded actions (MulticallHandler or weiroll)
  bytes deobfuscation; // If user action was obfuscated
}
```

## Execution Flow

1. **OrderGateway** computes orderId from Order + domain separation
2. **OrderGateway** applies auction changes if present (signed by auctionAuthority)
3. **Executor** runs submitter actions
4. **Executor** checks all requirements are met (token balance, submitter, deadline, etc.)
5. **Executor** calls **IUserActionExecutor** with current step's action
6. **IUserActionExecutor** executes action and propagates `nextSteps` cross-chain

For destination chains:

- Tokens arrive via bridge → **OrderStore**
- Submitter calls `fill()` to execute the step
- Same Executor → IUserActionExecutor flow

## Design Decisions

**Order ID Scope**: Computed once at OrderGateway with domain separation (srcChainId). Not propagated cross-chain.

**Cross-Chain Tracking**: Uses bridge-native identifiers (OFT guid, CCTP nonce, etc.). API/indexer correlates the full chain.

**Multi-Chain Orders**: `nextSteps` are ABI-encoded in bridge messages, enabling true multi-hop orders.

**Token Custody**: Tokens sit in OrderStore until fill. During step execution, temporarily in Executor. Executor should never have approvals.

**Requirement Checking**: Happens after submitter actions complete (swaps produce tokens before checking).

**Failure Handling**: Entire transaction reverts. Atomic, all-or-nothing.

**Refunds**: Permissionless after deadline - anyone can trigger, tokens go to `refundRecipient`.

**Obfuscation**: Trust-based. If user needs to hide their action, they specify a trusted submitter via `submitterReq`.

**Action Format**: Type prefix byte indicates format (0 = MulticallHandler, 1 = weiroll, etc.).

**Optional Fields**: Empty bytes (length 0) means no requirement.

## Integration Paths

**CCTP/OFT flows**: BridgeHandler → OrderStore.handle() → fill()

**Across (SpokePool)**: Uses `handleV3AcrossMessage` wrapper that routes to IUserActionExecutor directly (skips OrderStore since SpokePool already checks requirements).

## Sponsorship

Two models supported:

1. **Phase0-compatible**: Uses an Order with a single user action, which conatins all of the Phase0 parameters (including
   the API signature). Essentially hands over execution to the Phase0 system after src chain's submitterActions-reqChecks-
   -userAction sequence is done.
2. **Off-chain**: API reimburses relayers post-execution based on orderId and execution chain tracking by the Indexer. API
   only sponsors orders it can track completion of.
