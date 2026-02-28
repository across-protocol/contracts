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

**OrderGateway** - Entry point for all order submissions

- `submit()` calculates `orderId` and pulls tokens from user and submitter (gasless- or approval-based)
- Pushes all of the tokens to `Executor` based on `ForwardingAmounts` specified by the submitter

**Executor** - Executes a single step (a series of atomic substeps)

- Runs a series of substeps

AuctionSubmitterUser variant:

- Run auction substep (produces `Changes` to modify user requirements in the later step)
- Run submitter substep (e.g. DEX swaps, or taking a fee as long as it meets token requirement later)
- Run user step: check requirements and execute transfer or action (based on `UserSubstepType`). Action variant calls
  `IUserActionExecutor`

AuctionSubmitterUser

- only submitter and user parts from above

User

- only user part

TBD: ForwardingAmounts have to be presented either by user in `parts` or by submitter in `parts`. TBD by implementation

**IUserActionExecutor** - Final action interface

- Receives tokens and executes user-specified action (e.g. bridge via OFT / CCTP / deposit into SpokePool)
- Propagates `nextSteps` to continue cross-chain execution

**OrderStore** - Destination-side order management

- `handle()` - Receive tokens from bridge, store for filling
- `handleAtomic()` - Receive and fill in one transaction
- `fill()` - Fill a stored order

## Design Decisions

**Order ID Scope**: Computed once at OrderGateway with domain separation (srcChainId). Propagated cross-chain, but can be
spoofed on destination chains. Crosschain tracking is done as described below.

**Cross-Chain Tracking**: Uses bridge-native identifiers (OFT guid, CCTP nonce, etc.). API/indexer correlates the full chain.

**Multi-Chain Orders**: `nextSteps` are passed with bridge messages, enabling multi-hop orders.

**Token Custody**: Tokens sit in OrderStore until fill. During step execution, temporarily in Executor. Executor should never have approvals.

**Refunds**: Permissionless after reverse deadline - anyone can trigger, tokens go to `refundSettings.refundRecipient`.

**Obfuscation**: Trust-based. If user needs to hide their action, they specify a trusted submitter via `submitterReq`.

## Dst chain paths

**CCTP/OFT flows**: Oft/CctpHandler → OrderStore.handle() → fill()
\*Cctp finalizer can call CctpHandler.handleAtomic → OrderStore.handleAtomic()

**Across (SpokePool)**: Uses `handleV3AcrossMessage` wrapper that routes to IUserActionExecutor directly (skips OrderStore since SpokePool already checks requirements).

## Sponsorship

Two models supported:

1. **Phase0-compatible**: Uses an Order with a single user action, which conatins all of the Phase0 parameters (including
   the API signature). Essentially hands over execution to the Phase0 system after src chain's submitterActions-reqChecks-
   -userAction sequence is done.
2. **Off-chain**: API reimburses relayers post-execution based on orderId and execution chain tracking by the Indexer. API
   only sponsors orders it can track completion of.
