# Counterfactual Deposit Addresses

Counterfactual deposit addresses are CREATE2-deployed clone proxies that can receive funds before deployment and later execute one of several bridge routes.

The system now supports **two backend commitment modes**:

- `CounterfactualDepositMultiBridge` (Merkle proofs)
- `CounterfactualDepositMultiBridgeSimple` (direct per-route hashes, no proofs)

Both are non-custodial and reuse the same bridge execution modules.

## Contracts

- `CounterfactualDepositFactory`
  - Generic CREATE2 clone factory (`deploy`, `deployAndExecute`, `deployIfNeededAndExecute`, `predictDepositAddress`, `execute`)
  - Commits exactly one immutable arg on each clone: `paramsHash`
- `CounterfactualDepositBase`
  - Shared withdraw logic and clone `paramsHash` verification
  - Shared constants (`BPS_SCALAR`, `EXCHANGE_RATE_SCALAR`, `NATIVE_ASSET`)
- `CounterfactualDepositCCTPModule`
  - CCTP route execution
- `CounterfactualDepositOFTModule`
  - OFT route execution (payable; forwards `msg.value` to OFT src periphery)
- `CounterfactualDepositSpokePoolModule`
  - SpokePool route execution, EIP-712 signature verification, fee bound checks, native token support
- `CounterfactualDepositMultiBridge`
  - Merkle-proof backend
- `CounterfactualDepositMultiBridgeSimple`
  - Direct per-route hash backend
- `AdminWithdrawManager`
  - Optional manager for admin withdrawal workflows

## Shared model

### Clone commitment

For any backend, the clone stores:

- `paramsHash = keccak256(abi.encode(config))`

At execution or withdrawal, callers provide `config` (ABI-encoded) and the contract verifies it against the stored hash.

### Withdraw addresses

Both backend configs include:

- `userWithdrawAddress`
- `adminWithdrawAddress`

`userWithdraw` requires `msg.sender == userWithdrawAddress`.
`adminWithdraw` and `adminWithdrawToUser` require `msg.sender == adminWithdrawAddress`.

## Backend A: Merkle (`CounterfactualDepositMultiBridge`)

Config:

```solidity
struct CounterfactualDepositGlobalConfig {
  bytes32 routesRoot;
  address userWithdrawAddress;
  address adminWithdrawAddress;
}
```

Route leaves are hashed as:

- CCTP leaf: `keccak256(abi.encode(uint8(BridgeType.CCTP), cctpRouteHash))`
- OFT leaf: `keccak256(abi.encode(uint8(BridgeType.OFT), oftRouteHash))`
- SpokePool leaf: `keccak256(abi.encode(uint8(BridgeType.SPOKE_POOL), spokePoolRouteHash))`

Execution entrypoints verify:

1. `keccak256(abi.encode(config)) == stored paramsHash`
2. supplied Merkle proof proves the route leaf is in `config.routesRoot`
3. route-specific execution rules

## Backend B: Simple route hashes (`CounterfactualDepositMultiBridgeSimple`)

Config:

```solidity
struct CounterfactualDepositSimpleConfig {
  bytes32 cctpRouteHash;
  bytes32 oftRouteHash;
  bytes32 spokePoolRouteHash;
  address userWithdrawAddress;
  address adminWithdrawAddress;
}
```

Semantics:

- `routeHash == bytes32(0)` means that bridge route is disabled
- `routeHash != bytes32(0)` means enabled and must equal `keccak256(abi.encode(route))`

Execution entrypoints verify:

1. `keccak256(abi.encode(config)) == stored paramsHash`
2. selected route hash is non-zero and equals the route hash
3. route-specific execution rules

## Bridge route structs

### CCTP

`CCTPRoute`:

- `depositParams: CCTPDepositParams`
- `executionFee`

Behavior:

- Pays `executionFee` to `executionFeeRecipient`
- Approves and calls `SponsoredCCTPSrcPeriphery.depositForBurn`
- `maxFee` is derived from `cctpMaxFeeBps`

### OFT

`OFTRoute`:

- `depositParams: OFTDepositParams`
- `executionFee`

Behavior:

- Pays `executionFee` to `executionFeeRecipient`
- Approves and calls `SponsoredOFTSrcPeriphery.deposit{value: msg.value}`
- OFT native messaging fee is supplied by caller via `msg.value`

### SpokePool

`SpokePoolRoute`:

- `depositParams: SpokePoolDepositParams`
- `executionParams: SpokePoolExecutionParams`

Behavior:

- Verifies EIP-712 signature for execution fields
- Enforces fee bound: `relayerFee + executionFee <= maxFeeFixed + maxFeeBps * inputAmount / 10000`
- Supports native input with `NATIVE_ASSET` sentinel and `wrappedNativeToken` substitution
- Depositor passed to SpokePool is clone address

EIP-712 domain for SpokePool module:

- name: `CFSpokePool`
- version: `1`

## Factory usage

Typical flows:

1. Off-chain compute backend config and `paramsHash`.
2. Predict address with `predictDepositAddress(implementation, paramsHash, salt)`.
3. User sends funds to predicted address (before deployment).
4. Relayer executes:
   - `deployAndExecute(...)` or
   - `deployIfNeededAndExecute(...)` (idempotent) or
   - direct call to deployed clone.

## Choosing a backend

Use `CounterfactualDepositMultiBridge` when:

- You want flexible allowlists with compact on-chain config (`routesRoot`)
- You already have proof generation infrastructure

Use `CounterfactualDepositMultiBridgeSimple` when:

- You want simpler backend logic
- Route set is small/static and direct hash commitments are sufficient

## Errors

Shared interface errors include:

- `InvalidParamsHash`
- `InvalidRouteProof` (Merkle backend)
- `InvalidRouteHash` (Simple backend)
- `RouteDisabled` (Simple backend)
- `InvalidSignature`, `SignatureExpired` (SpokePool path)
- `MaxFee` (SpokePool path)
- `Unauthorized`, `NativeTransferFailed`
