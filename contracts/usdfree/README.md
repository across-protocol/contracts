# USDFree

A cross-chain order system that unifies CCTP, OFT, and Across bridge flows into a single architecture and allows for expanding to new underlying bridge types easily, as well as performing same-chain TXs with no cross-chain execution.

## Goals

- Bridge tokens cross-chain regardless of underlying mechanism
- Use auction systems for token swaps when needed
- Support same-chain actions with no briding, as well as action chaining
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

- `submit()` calculates `orderId` and pulls tokens from user and submitter (gasless- or approval-based)
- Pushes all of token amounts to `Executor` upon receiving, without leaving tokens to self.
  // TODO: consider if we even need to support this at the Gateway level. Should underlying protocols take care of this instead? I guess this feels like an optimization, where a DstPeriphery contract may not be required, where it otherwise could have been required.
- can store prefunded orders waiting for execution (e.g. if submitter was not available yet on DST chain, for example the case with OFT leg completion, where endpoint automatically pushes funds somewhere).

**Executor** - Executes a single Step

It's biggest feature is being able to perform untrusted

A few big features:

- command-based: there's a growing list of commands that can be performed (Dispatcher pattern by Uniswap). Command is like an enum, there's some user data and some submitter data that can go into each command. Command definition defines what data gets pulled.
- can perform external calls to untrusted external contracts from its own context (One of commands). Each call can include balance of some token, or a partial balance. A command like `makeCallWithBalance` can e.g. substitute some static part of user-defined calldata for current balance (useful for e.g. final user action)
- commands are defined by user order, but a command can use executorMessage from submitterData when relevant (e.g. a user allows submitter to perform arbitrary calls at a certain command. The submitter can even transfer all of the tokens out of the contract if they so wish. It will later get checked by a user-defined requirement, e.g. a token balance requirement)

Some common functions/commands:

- requirement checks (provided by the user: token, submitter, deadline)
- auction-based requirement augmentation (auction settings provided by user, auction data for offchain auctions by submitter). Auctions can be off-chain and on-chain(e.g. dutch OR X-percent-over-oracle requirement, which is not really an auction, but more of a dynamic requirement).
- DEX swaps (command defined by user, data by submitter). Or submitter contract interaction; user let's a submitter free rein at a certain point of execution
- final user action: can be just a transfer or can be a call to the bridge (with e.g. some part of calldata dynamically substituted like in makeCallWithBalance). We may need to support more complicated substitutions for parts of user-provided static calldata to the bridge. We can have something like makeCallWithStorageData, which will read some data that submitter stored into storage e.g. during custom actions step and place at a certain byte offstet into the user calldata. This is advanced functionality.

## Design Decisions

**Order ID**: used as witness in orderOwner gasless funding; can be forced unique if nonce != 0; can be used for (orderId => sponsorship) mapping with a uniqueness guarantee. Order ID is effectively a hash over the "suffix" of the order. Each new execution Step gets its own orderId. When tracking sponsorship execution, offchain actor can demand that an array of orderIds was emitted to guarantee sponsorship rebate.

**Execution ID**: used as witness for submitter gasless funding.

**Step ID**: when an order contains merkle root, sometimes we want to sponsor a specific Path through that tree only. Step ID helps disambiguate which execution really happened.

**Obfuscation**: If an order contains a merkle tree root, each leaf gets a salt, which can be selectively disclosed by the API.

## Underlying bridge support

Current focus is CCTP/SpokePool/OFT. Two interaction modes:

### Hand-off mode

Executor performs a single source-chain leg (e.g. approve + call bridge) and hands off to the existing bridge system. The bridge delivers tokens to whatever destination recipient/handler is already in place. No custom destination periphery is needed from USDFree's side.

- **OFT**: Executor calls into `SponsoredOFTSrcPeriphery`, which handles quote validation, token pull, and `IOFT.send()` with compose. LayerZero endpoint delivers funds + compose to an existing `DstOFTHandler` on destination.
- **CCTP**: Executor calls into `SponsoredCCTPSrcPeriphery`, which handles quote validation, token pull, and `ITokenMessengerV2.depositForBurnWithHook()`. Circle attestation delivers funds to an existing `SponsoredCCTPDstPeriphery` on destination.
- **SpokePool**: Executor calls `V3SpokePoolInterface.depositV3()` (`V3SpokePoolInterface.sol`). Across relayer fills on destination; if a message is included, fill calls `AcrossMessageHandler.handleV3AcrossMessage()` (`SpokePoolMessageHandler.sol`) on the recipient.

In all cases the source Executor just needs the right command to build the bridge call (with balance substitution via `makeCallWithBalance` if needed).

### Integration mode

Tokens are delivered into `OrderGateway` on the destination chain, enabling the full USDFree feature set on dst: custom action execution, sponsorship rebates, and submitter-provided auction data. The goal is **atomic dst execution** wherever the bridge allows it.

- **OFT**: Atomic execution is not possible — LayerZero compose auto-delivers funds before a submitter can act. `OrderGateway` stores a prefunded order; a submitter calls `OrderGateway.submit()` in a separate tx to continue execution through a new Step.
- **CCTP**: Atomic execution is possible. A new dst contract (e.g. `CCTPOrderReceiver`) accepts the Circle attestation + `submitterInputs` in a single call. It calls `IMessageTransmitterV2.receiveMessage()` to mint tokens, then atomically calls `OrderGateway.submit()` with the order + submitter data — full dst execution in one tx.
- **SpokePool**: Atomic execution is possible via a `SpokePoolWrapper`. The relayer calls `SpokePoolWrapper.fillV3Relay(...)` providing `submitterData` alongside the fill. The wrapper calls into `SpokePool` to perform the fill; SpokePool calls back into the wrapper via `AcrossMessageHandler.handleV3AcrossMessage()` (the user's message encodes the order); the wrapper then calls `OrderGateway.submit()` with the relayer-provided submitter data. Technicality: `exclusiveRelayer` must be set to the wrapper (or handled via delegation) so the relayer can fill through it.
