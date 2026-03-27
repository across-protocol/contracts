# USDFree

A cross-chain order system that unifies CCTP, OFT, and Across bridge flows into a single architecture and allows for expanding to new underlying bridge types easily, as well as performing same-chain TXs with no cross-chain execution.

## Goals

- Bridge tokens cross-chain regardless of underlying mechanism
- Use auction systems for token swaps when needed
- Support same-chain actions with no bridging, as well as action chaining
- Single upgradeable entry point (no re-approvals needed)
- Support gasless flows and sponsorship with deferred sponsorship rebates for sponsoring submitters
- Execute arbitrary user actions after token delivery

## Architecture

```
Source Chain:
User AND/OR Submitter → OrderGateway → Executor -custom-call-> OFT/CCTP/SpokePool/CustomAdapterIfNeeded
                                          ↓
                                  [Bridge Message]
                                          ↓
                                  Destination Chain:
BridgeCapitalProvider/CustomHandlerIfNeeded → OrderGateway → Executor -custom-call-> OFT/CCTP/SpokePool/CustomAdapterIfNeeded
```

### Components

**OrderGateway** - Entry point for all order submissions

- `submit()` calculates `orderId`, resolves the concrete `Step` (direct step or Merkle leaf + proof), pulls funding from `orderOwner` and/or submitter, and forwards all received assets into `Executor` without intentionally retaining balances.
- Core v1 funding adapters:
  - allowance-based `approve + transferFrom`
  - Permit2 witness-based transfers
  - TransferWithAuthorization / EIP-3009-style funding, where the witness is effectively the authorization nonce
- Bridge-delivered funds are not a special funding type in the core. A bridge receiver / wrapper that already holds funds should fund the next step using a normal adapter, most likely allowance-based `approve + transferFrom`.
- `orderOwner` is a namespace + funding authority, not always `msg.sender`. However, if a receiver / wrapper funds a later step itself, that caller should usually also be the `orderOwner` for that step.
- For core purposes, `submitter` is always `msg.sender` to `submit()`. `OrderGateway` passes that address into `Executor`; `Executor` trusts `OrderGateway` one-way. The core does not accept protocol-specific "real submitter" addresses forwarded in from outside systems.
- Can store prefunded orders waiting for continuation when a bridge auto-delivers funds before fresh submitter input is available.
- v1 prefunded continuations use a monotonic local counter. A stored continuation can be resumed by any caller that satisfies the later `Executor` requirements, and `refundAddress` may withdraw associated funds after `refundReverseDeadline`.

**Executor** - Executes a single Step

Big features:

- Command-based execution (Dispatcher pattern by Uniswap). The user defines the command sequence and static data. A command opts into reading submitter-provided dynamic data from `executorMessage` only when that command needs it.
- Can perform external calls to untrusted contracts from its own context. Calls can substitute current balance or partial balance into user-provided calldata, which is especially useful for DEX swaps and final bridge / user actions.
- The user can intentionally give a submitter a free-form custom-call window. In that case the submitter may move all assets out of the contract; the user's later requirements are the safety boundary.

Some common functions/commands:

- `balanceRequirement`
- `deadlineRequirement`
- `submitterRequirement`
- `offchainAuction`: the user precommits auction settings, including the authority. The command requires an authority signature over the result for that particular command. The result can augment user requirements, especially by adding `balanceRequirement` or `submitterRequirement`.
- `dutchOnChainAuction`
- `customCalls`: submitter-provided calls to DEXes or opaque submitter contracts, with balance or partial-balance substitution
- final user / bridge action: simple transfers, or calls into `IOFT`, Circle token messenger (`depositForBurnWithHook`), `V3SpokePoolInterface.depositV3()`, `SponsoredCCTPSrcPeriphery`, `SponsoredOFTSrcPeriphery`, etc.
- More advanced calldata substitution is plausible later (for example injecting data previously produced by a custom call), but balance-based substitution is the important first-class primitive.
- Initial v1 implementation should prioritize the non-auction primitives above. Auction / oracle-priced requirement commands can follow after the initial implementation.

## Design Decisions

**Order ID**: used as witness in `orderOwner` gasless funding. It identifies the order envelope, not necessarily a single executable leaf. If `nonce == 0`, the core does not enforce uniqueness for that `orderId`, which saves an `SLOAD + SSTORE`. If `nonce != 0`, uniqueness can be enforced and used as a clean primitive for offchain systems that want stable `(orderId => sponsorship / rebate / bookkeeping)` mappings.

**Execution ID**: used as witness for submitter gasless funding. Since the core submitter is always `msg.sender` to `OrderGateway`, `executionId` is scoped to the direct caller of `submit()`, not to some bridge-specific actor behind that caller.

**Step ID**: needed only when an order contains a Merkle root. In that case multiple leaves share the same `orderId`, and `stepId` disambiguates which disclosed path was actually executed. In v1, `stepId` includes the disclosed leaf salt. For non-Merkle orders, emitting `orderId` is enough.

**TypedData**: `TypedData` is intentionally just `(typ, data)`. Each consumer defines its own local type registry and decoding rules. In particular, `order.stepOrMerkleRoot` is interpreted by `OrderGateway` as either a directly-encoded `Step` or a `bytes32` Merkle root.

**Merkle execution**: absolutely in scope. The submitter provides the disclosed `Step` plus Merkle proof. The core does not enforce leaf-level single execution. Single execution comes mostly from gasless funding nonces and, when desired, from order-level uniqueness via `order.nonce`.

**Merkle leaf hashing**: when `order.stepOrMerkleRoot` is a Merkle root, the v1 step / leaf hash is `keccak256(abi.encode(step.salt, step.executor, keccak256(step.message)))`. `stepId` should use the same salted step hash.

**Refund settings**: this is for the user, not for sponsorship accounting. The minimal shape is versioned `(refundAddress, refundReverseDeadline)`-style liveness / escape-hatch configuration in case execution stalls at some step. Sponsorship refunds are handled offchain.

**Prefunded continuations**: continuation storage should be keyed independently from `orderId`, using a monotonic local counter rather than a user-chosen or hash-derived predictable id. This avoids collisions / griefing around continuation identifiers and keeps the prefund mechanism as a local storage concern.

**Obfuscation**: If an order contains a merkle tree root, each leaf gets a salt, which can be selectively disclosed by the API.

**Upgradeability / trust**: `OrderGateway` is UUPS upgradeable. `step.executor` is user-chosen; users decide what executor code they trust. `OrderGateway` should treat executors as untrusted external contracts and must not rely on them beyond the narrow call boundary it controls.

## Underlying bridge support

Current focus is CCTP/SpokePool/OFT. Two interaction modes:

### Hand-off mode

Executor performs a single source-chain leg (e.g. approve + call bridge) and hands off to the existing bridge system. The bridge delivers tokens to whatever destination recipient / handler is already in place. No custom destination periphery is needed from USDFree's side.

- **OFT**: Executor calls into `SponsoredOFTSrcPeriphery`, which handles quote validation, token pull, and `IOFT.send()` with compose. LayerZero endpoint delivers funds + compose to an existing `DstOFTHandler` on destination.
- **CCTP**: Executor calls into `SponsoredCCTPSrcPeriphery`, which handles quote validation, token pull, and `ITokenMessengerV2.depositForBurnWithHook()`. Circle attestation delivers funds to an existing `SponsoredCCTPDstPeriphery` on destination.
- **SpokePool**: Executor calls `V3SpokePoolInterface.depositV3()` (`V3SpokePoolInterface.sol`). Across relayer fills on destination; if a message is included, fill calls `AcrossMessageHandler.handleV3AcrossMessage()` (`SpokePoolMessageHandler.sol`) on the recipient.

In all cases the source Executor just needs the right command to build the bridge call (with balance substitution via `makeCallWithBalance` if needed).

### Integration mode

Tokens are delivered into `OrderGateway` on the destination chain, or into a thin receiver / wrapper that funds and calls `OrderGateway` as the next `orderOwner`. This enables the full USDFree feature set on dst: custom action execution, user refund settings, and submitter-provided auction data. The goal is **atomic dst execution** wherever the bridge and wrapper model allow it, while keeping the core bridge-agnostic.

- **OFT**: Atomic destination execution is possible only for fully precommitted destination logic encoded into compose data. Fresh destination-side submitter input is not available in that same tx. Therefore, if the destination step needs fresh submitter-provided data or funding, OFT degrades to a prefunded continuation: a receiver contract stores / owns the bridged funds, and a later `submit()` continues the flow as a new step.
- **CCTP**: Atomic execution is possible. A dst contract (e.g. `CCTPOrderReceiver`) accepts the Circle attestation, receives funds, and then calls `OrderGateway.submit()` in the same tx. Since the core does not trust protocol-specific claimed submitters, the receiver itself is the Gateway submitter for that step. If the receiver wants to enforce properties about the external attestation caller or other bridge-specific actor, it must do so before forwarding into the core.
- **SpokePool**: Atomic execution is possible via a `SpokePoolWrapper` used as the Across recipient. SpokePool calls the wrapper via `AcrossMessageHandler.handleV3AcrossMessage()`, which gives the wrapper the bridge-authenticated relayer address. The wrapper can check bridge-specific conditions there (for example relayer-based requirements or exclusivity assumptions), then fund and call `OrderGateway.submit()` itself. Core submitter identity still remains `msg.sender` to `OrderGateway`, i.e. the wrapper, not a relayer address forwarded through trust.
