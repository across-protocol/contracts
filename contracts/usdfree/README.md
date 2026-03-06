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
- Pushes all of token amounts to `Executor`. Pushes tokens one by one starting from the orderFunding token. If submitter
  provided extraFunding and the first token in that array is the same as the orderFunding token, the amounts get pushed
  via a single Transfer to reduce gas costs.

**Executor** - Executes a single step (a series of atomic substeps)

- Runs a series of substeps

_AlterSubmitterUser_ variant

- Run alter substep (produces `Changes` to modify user requirements in the later step):
  alter user requirements may take many different forms. For example, an offchain auction authority can sign
  over some payload to bump up the user's balanceReq. Or a user can trust a submitter (e.g. RL submitter) to bump
  up balanceReq (effectively, this is the same as having auction authority == RL submitter). Alternatively, imagine
  an Alter substep that: takes token amount in (from mint on dst chain), takes onchain oracle price, takes user
  BPS discount / premium required, alters balanceReq: balanceReq = tokenIn _ price _ (1 + bps_disc_or_premium)
- Run submitter substep (e.g. DEX swaps, or taking a fee as long as it meets user balance requirement in the next step)
- Run user substep: check requirements and execute transfer or action (based on `UserSubstepType`). Action variant calls
  `IUserActionExecutor`. Transfer is push-based, action is approve-tranferFrom-based.

_SubmitterUser_

- only submitter and user substeps from above

_User_

- only user substep

**IUserActionExecutor** - Final action interface

- Pull tokens from Executor using the provided tokenAmount
- Execute user-specified action. For example, talk to IOFT to bridge tokens over to the next chain. It's the responsibility
  of the user action executor to propagate next steps correctly to the next execution leg (e.g. in `composeMsg` for OFT).
  Other bridge options can include CCTP, SpokePool and others.

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

**SpokePool**: Uses `handleV3AcrossMessage` wrapper that routes to IUserActionExecutor directly (skips OrderStore since SpokePool already checks requirements).

## Sponsorship

Two models supported:

1. **Phase0-compatible**: Uses an Order with a single user action, which conatins all of the Phase0 parameters (including
   the API signature). Essentially hands over execution to the Phase0 system after src chain's submitterActions-reqChecks-
   -userAction sequence is done.
2. **Off-chain**: API reimburses relayers post-execution based on orderId and execution chain tracking by the Indexer. API
   only sponsors orders it can track completion of.
