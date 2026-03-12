# Handlers

This folder contains destination message handlers used by Across-style flows.

## TopUpGateway

`TopUpGateway` is a signature-gated execution gateway for flows where relayers may need to top up funds to satisfy an exact settlement amount (for example, targeting a 1:1 UX after swap slippage).

File: `contracts/handlers/TopUpGateway.sol`

### What it does

`TopUpGateway` receives tokens and a message, then:

1. Hashes execution data into an EIP-712 digest (used as Permit2 witness).
2. Enforces nonce replay protection and deadline.
3. Pulls relayer top-up authorization via Permit2 witness signature.
4. Executes one arbitrary `target.call(callData)`.
5. Refunds leftover token/native balance to `refundTo`.

### Security model (current v0)

Current behavior is intentionally open:

1. Any caller can call `handleV3AcrossMessage`.
2. Any `target` and any selector are allowed.

Because of this, safety depends primarily on:

1. Permit2 witness signature correctness.
2. Nonce uniqueness.
3. Deadline checks.
4. Relayer top-up limits (`topupMax`).

If you later need stricter policy controls, add caller/target/selector allowlists in a future version.

## Integration with other contracts

### 1) With `SpokePoolPeriphery` + `TransferProxy`

This is the primary composition pattern for gasless relayer-submitted flows:

1. User signs gasless swap-and-bridge input for `SpokePoolPeriphery`.
2. Relayer submits `swapAndBridgeWithPermit2` (or permit variant).
3. Set `spokePool = TransferProxy`.
4. Set `recipient = TopUpGateway`.
5. Put the encoded `TopUpGateway` message in the Across message field.
6. `TransferProxy` transfers output token to `TopUpGateway` and invokes `handleV3AcrossMessage`.
7. `TopUpGateway` executes top-up + target call atomically on source chain.

Relevant files:

1. `contracts/SpokePoolPeriphery.sol`
2. `contracts/TransferProxy.sol`
3. `contracts/handlers/TopUpGateway.sol`

### 2) With `SponsoredCCTPSrcPeriphery`

Use `TopUpGateway` as a generic pre-execution settlement layer before CCTP:

1. `target = SponsoredCCTPSrcPeriphery`.
2. `callData = abi.encodeCall(SponsoredCCTPSrcPeriphery.depositForBurn, (quote, quoteSig))`.
3. `requiredAmount` should match `quote.amount` in your offchain policy/signing logic.

This lets relayers top up shortfalls before calling CCTP burn.

Relevant files:

1. `contracts/periphery/mintburn/sponsored-cctp/SponsoredCCTPSrcPeriphery.sol`
2. `contracts/interfaces/SponsoredCCTPInterface.sol`

## Message format

`TopUpGateway.handleV3AcrossMessage` expects:

`abi.encode(execution, permit, permit2Signature)`

Where:

1. `execution` is `TopUpGateway.ExecutionData`
2. `permit` is `IPermit2.PermitTransferFrom`
3. `permit2Signature` is required and is the only signature

### `ExecutionData` fields

1. `nonce`
2. `deadline`
3. `inputToken`
4. `requiredAmount`
5. `relayer`
6. `refundTo`
7. `topupMax`
8. `target`
9. `value`
10. `callData`

## Signing details

### Permit2 witness signature

Relayer signs a Permit2 witness transfer where witness is the gateway execution digest.

`TopUpGateway` exposes:

1. `PERMIT2_WITNESS_TYPE_STRING`
2. `executionDigest(...)`

These are used by relayer infra to construct Permit2 signatures.

Why one signature is enough:

1. The execution digest is embedded as the Permit2 witness.
2. Permit2 verifies the relayer signature against both transfer details and witness.
3. This binds top-up authorization and execution intent in one signed payload.

## Typical flow for exact settlement

1. Swap path provides `X` tokens to gateway.
2. Signed execution requires `requiredAmount = Y`.
3. If `X < Y`, gateway pulls `Y - X` from relayer (bounded by `topupMax`).
4. Gateway executes target call with `Y`.
5. Gateway refunds leftovers to relayer or designated `refundTo`.

## Operational recommendations

1. Use short deadlines.
2. Never reuse nonces.
3. Use conservative `topupMax`.
4. Use pause/cancel nonce in incident response.

## Admin controls

Owner can:

1. `cancelNonce(bytes32)`
2. `pause()`
3. `unpause()`

## Tests

See:

1. `test/evm/foundry/local/TopUpGateway.t.sol`

Covered scenarios include:

1. Valid execution + refund.
2. Replay protection.
3. Invalid signature rejection.
4. Permit2 top-up path.
5. Missing Permit2 signature when top-up is required.
