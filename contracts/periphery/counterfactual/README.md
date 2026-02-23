# Counterfactual Deposit Addresses

Counterfactual deposit addresses are CREATE2-deployed clone proxies that can receive funds before deployment and execute pre-committed bridge routes later.

The system supports **three backend commitment modes**:

- `CounterfactualDepositMultiBridge` (typed Merkle routes for built-in bridge families)
- `CounterfactualDepositMultiBridgeSimple` (direct per-route hashes, no Merkle proofs)
- `CounterfactualDepositMultiBridgeModular` (Merkle-routed modular dispatcher with delegatecall modules)

All three are non-custodial and use the same CREATE2/predict/deploy semantics.

## Contracts

- `CounterfactualDepositFactory`
  - Generic CREATE2 clone factory (`deploy`, `deployAndExecute`, `deployIfNeededAndExecute`, `predictDepositAddress`, `execute`)
  - Commits one immutable clone arg: `paramsHash`
- `CounterfactualDepositBase`
  - Shared withdraw logic and `paramsHash` verification
  - Shared constants: `BPS_SCALAR`, `EXCHANGE_RATE_SCALAR`, `NATIVE_ASSET`
- `CounterfactualDepositCCTPModule`
  - CCTP execution logic
- `CounterfactualDepositOFTModule`
  - OFT execution logic (payable; forwards `msg.value`)
- `CounterfactualDepositSpokePoolModule`
  - SpokePool execution logic, EIP-712 signature checks, fee bounds, native handling
- `CounterfactualDepositMultiBridge`
  - Typed Merkle backend for CCTP/OFT/SpokePool
- `CounterfactualDepositMultiBridgeSimple`
  - Simple hash backend for CCTP/OFT/SpokePool
- `CounterfactualDepositMultiBridgeModular`
  - Generic modular Merkle dispatcher
- `CounterfactualDepositModularCCTPModule`
  - Delegatecall module adapter for CCTP routes
- `CounterfactualDepositModularOFTModule`
  - Delegatecall module adapter for OFT routes
- `CounterfactualDepositModularSpokePoolModule`
  - Delegatecall module adapter for SpokePool routes
- `ICounterfactualDepositRouteModule`
  - Common interface for modular route modules:
    - `execute(bytes guardrailParams, bytes submitterParams)`
- `AdminWithdrawManager`
  - Optional manager for admin withdrawal workflows

## Shared model

For any backend, the clone verifies:

- `stored paramsHash == keccak256(abi.encode(config))`

Withdraw permissions are always committed in config:

- `userWithdrawAddress` for `userWithdraw`
- `adminWithdrawAddress` for `adminWithdraw` and `adminWithdrawToUser`

## Backend A: Typed Merkle (`CounterfactualDepositMultiBridge`)

Config:

```solidity
struct CounterfactualDepositGlobalConfig {
  bytes32 routesRoot;
  address userWithdrawAddress;
  address adminWithdrawAddress;
}
```

Leaf format is bridge-family typed:

- CCTP: `keccak256(abi.encode(uint8(BridgeType.CCTP), keccak256(abi.encode(cctpRoute))))`
- OFT: `keccak256(abi.encode(uint8(BridgeType.OFT), keccak256(abi.encode(oftRoute))))`
- SpokePool: `keccak256(abi.encode(uint8(BridgeType.SPOKE_POOL), keccak256(abi.encode(spokeRoute))))`

Execution verifies:

1. config hash matches clone commitment
2. Merkle proof includes the selected typed route leaf
3. route-specific execution rules

## Backend B: Simple Hash (`CounterfactualDepositMultiBridgeSimple`)

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

Semantics per route:

- `hash == 0`: route disabled
- `hash != 0`: route enabled and must equal `keccak256(abi.encode(route))`

Execution verifies config hash and per-route hash equality, then executes the same underlying bridge logic.

## Backend C: Modular Merkle Dispatcher (`CounterfactualDepositMultiBridgeModular`)

Uses the same `CounterfactualDepositGlobalConfig` as Backend A.

Leaf format is generic:

- `keccak256(abi.encode(moduleImplementation, keccak256(guardrailParams)))`

Dispatcher entrypoint:

```solidity
execute(
  CounterfactualDepositGlobalConfig globalConfig,
  address implementation,
  bytes guardrailParams,
  bytes submitterParams,
  bytes32[] proof
)
```

Execution verifies:

1. config hash matches clone commitment
2. `implementation` has bytecode
3. Merkle proof includes `(implementation, keccak256(guardrailParams))`
4. delegatecall to `implementation.execute(guardrailParams, submitterParams)`

This enforces a clean split:

- user commitments: `guardrailParams` (Merkle-committed)
- submitter runtime inputs: `submitterParams` (not committed)

This makes new bridge families addable without touching the dispatcher contract: deploy a new module implementation that follows `ICounterfactualDepositRouteModule` and include `(implementation, guardrailHash)` leaves in the user’s Merkle root.

### Built-in modular adapters

- `CounterfactualDepositModularCCTPModule`
  - `guardrailParams = abi.encode(CCTPUserParams)`
  - `submitterParams = abi.encode(CCTPSubmitterParams)` (contains signature)
- `CounterfactualDepositModularOFTModule`
  - `guardrailParams = abi.encode(OFTUserParams)`
  - `submitterParams = abi.encode(OFTSubmitterParams)` (contains signature)
- `CounterfactualDepositModularSpokePoolModule`
  - `guardrailParams = abi.encode(SpokePoolUserParams)`
  - `submitterParams = abi.encode(SpokePoolSubmitterParams)` (contains signature)

## Route structs and behavior

### CCTP

`CCTPRoute`:

- `depositParams: CCTPDepositParams`
- `executionFee`

Behavior:

- pays `executionFee` to `executionFeeRecipient`
- approves and calls `SponsoredCCTPSrcPeriphery.depositForBurn`
- derives CCTP `maxFee` from `cctpMaxFeeBps`

### OFT

`OFTRoute`:

- `depositParams: OFTDepositParams`
- `executionFee`

Behavior:

- pays `executionFee` to `executionFeeRecipient`
- approves and calls `SponsoredOFTSrcPeriphery.deposit{value: msg.value}`
- OFT native messaging fee is provided via `msg.value`

### SpokePool

`SpokePoolRoute`:

- `depositParams: SpokePoolDepositParams`
- `executionParams: SpokePoolExecutionParams`

Behavior:

- verifies EIP-712 signature for execution fields
- enforces fee bound:
  - `relayerFee + executionFee <= maxFeeFixed + maxFeeBps * inputAmount / 10000`
- supports native input via `NATIVE_ASSET` sentinel and `wrappedNativeToken`
- sets clone address as SpokePool depositor

SpokePool EIP-712 domain:

- name: `CFSpokePool`
- version: `1`

## Factory usage

Typical flow:

1. Off-chain compute config and `paramsHash`.
2. Predict address with `predictDepositAddress(implementation, paramsHash, salt)`.
3. User funds predicted address.
4. Relayer executes with:
   - `deployAndExecute(...)`, or
   - `deployIfNeededAndExecute(...)` (idempotent), or
   - direct call to deployed clone.

## Choosing a backend

Use `CounterfactualDepositMultiBridge` when:

- fixed built-in bridge families are enough
- you want typed Merkle leaves per built-in family

Use `CounterfactualDepositMultiBridgeSimple` when:

- route set is small and static
- you prefer no Merkle proofs

Use `CounterfactualDepositMultiBridgeModular` when:

- you want plug-in bridge extensibility without dispatcher changes
- you want very clear separation between user guardrails and submitter runtime options
- backend can build Merkle leaves keyed by module implementation + guardrail hash

## Errors

Shared interface errors include:

- `InvalidParamsHash`
- `InvalidRouteProof`
- `InvalidRouteHash`
- `RouteDisabled`
- `InvalidModuleImplementation`
- `InvalidSignature`
- `SignatureExpired`
- `MaxFee`
- `Unauthorized`
- `NativeTransferFailed`
