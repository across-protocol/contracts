# Counterfactual Deposit Addresses

Gas-optimized system for creating persistent, reusable deposit addresses via deterministic CREATE2 deployment. Supports multiple bridge types: **CCTP**, **OFT** (LayerZero), and **SpokePool** (Across). Routes are authorized by a per-chain `RoutePolicy` whose merkle root the owner can update — so the set of supported routes can evolve without invalidating clone addresses.

## Architecture

**Generic factory + identity-bound clone + per-chain RoutePolicy + bridge-specific implementations:**

- `CounterfactualDepositFactory` — Bridge-agnostic factory. Deploys clones of `CounterfactualDeposit` deterministically via `Clones.cloneDeterministicWithImmutableArgs`, predicts addresses, and forwards raw calldata to clones. Takes the five `CloneArgs` identity fields as input.
- `CounterfactualDeposit` — Merkle-dispatched execution entrypoint. All clones are EIP-1167 proxies of this contract. The clone's sole immutable arg is `argsHash = keccak256(abi.encode(cloneArgs))` over the five identity fields. On execute, `CounterfactualDeposit` verifies the hash, either bypasses the policy (admin escape) or verifies the merkle proof against `IRoutePolicy(cloneArgs.routePolicyAddress).activeRoot(address(this))`, then delegatecalls the implementation.
- `RoutePolicy` — UUPS-upgradeable, `Ownable` contract holding a single merkle root that enumerates the routes a clone may execute on this chain. The owner (typically a multisig) calls `updateRoot(newRoot)` to swap the route set globally for every clone pointing at this policy, and `upgradeToAndCall(newImpl, data)` to evolve the implementation (e.g. add per-clone overrides) without changing the proxy's address. Deployed at the same address on every EVM chain; each chain holds its own per-chain root.
- `CounterfactualDepositSpokePool` — Deposit implementation for Across SpokePool. Verifies an EIP-712 signature itself (since it calls `SpokePool.deposit()` directly) and enforces a `maxFeeFixed + maxFeeBps × inputAmount` total-fee cap.
- `CounterfactualDepositCCTP` — Deposit implementation for SponsoredCCTP. Verifies a local EIP-712 signature authorizing the runtime `executionFee`, then forwards a `SponsoredCCTPQuote` to `SponsoredCCTPSrcPeriphery.depositForBurn()` along with the periphery's own quote signature.
- `CounterfactualDepositOFT` — Deposit implementation for SponsoredOFT (LayerZero). Same shape as CCTP plus `msg.value` forwarding for LZ native messaging fees.
- `WithdrawImplementation` — Withdraw implementation. Conforms to `ICounterfactualImplementation` like any other impl; self-protects by checking `msg.sender == admin`. Typically invoked by the clone's admin via `CounterfactualDeposit`'s admin escape.
- `AdminWithdrawManager` — Contract designed to be set as `admin` on clones that want managed withdraw access. Provides two paths: (1) direct withdraw by a trusted `directWithdrawer` to any recipient, and (2) signed withdraw by anyone with a valid EIP-712 signature from `signer`, where the signer fixes the recipient.
- `CounterfactualConstants` — Shared file-level constants (`NATIVE_ASSET`, `BPS_SCALAR`) imported by name.

```
Deployer / SDK
       │
       │ CREATE2 via deterministic-deployment proxy
       ▼
┌──────────────────────────────────────────────────────────────┐
│ CounterfactualDepositFactory                                 │
│   - deploy(dispatcher, cloneArgs, salt)                      │
│   - predictDepositAddress(...)                               │
│   - {deploy,deployIfNeeded}AndExecute(...)                   │
└──────────────────────────────────────────────────────────────┘
       │
       │ deploys
       ▼
┌──────────────────────────────────────────────────────────────┐
│ Clone (EIP-1167 proxy, ~77 bytes total)                      │
│   Immutable arg: argsHash = keccak256(abi.encode(            │
│     outputToken, destinationChainId, recipient,              │
│     admin, routePolicyAddress))                              │
└──────────────────────────────────────────────────────────────┘
       │
       │ DELEGATECALL (via EIP-1167)
       ▼
┌──────────────────────────────────────────────────────────────┐                ┌──────────────────────────────────────────┐
│ CounterfactualDeposit (no per-clone state)                   │                │ RoutePolicy (UUPS proxy, one per chain)  │
│   1. verifies keccak256(args) == clone.argsHash              │   staticcall   │   - owner: Across or integrator multisig │
│   2. if msg.sender == args.admin: skip merkle check          │ ─────────────► │   - root: merkle root over the chain's   │
│      else: verify merkle proof against policy root           │ activeRoot     │     4-dim route-leaf tree                │
│   3. delegatecall impl with verified args                    │ (address(this))│   - updateRoot(newRoot): replaces root   │
│                                                              │ ◄───────── b32 │   - upgradeToAndCall: evolves impl       │
└──────────────────────────────────────────────────────────────┘                └──────────────────────────────────────────┘
       │
       │ DELEGATECALL
       ▼
┌──────────────────────────────────────────────────────────────┐
│ Implementation.execute(                                      │
│   recipient, outputToken, destinationChainId,                │
│   admin, routeParams, submitterData)                         │
│                                                              │
│ - CCTP / OFT / SpokePool: verify signer EIP-712 over runtime │
│ - WithdrawImpl: msg.sender == admin check                    │
└──────────────────────────────────────────────────────────────┘
       │
       │ external CALL (or transfer)
       ▼
┌──────────────────────────────────────────────────────────────┐
│ Underlying contract                                          │
│   (Across SpokePool, SponsoredCCTPSrcPeriphery,              │
│    SponsoredOFTSrcPeriphery, or ERC-20 / native transfer)    │
└──────────────────────────────────────────────────────────────┘
```

- `address(this)` = clone address throughout (correct for EIP-712, token balances)
- `msg.sender` = original caller throughout the delegatecall chain
- `msg.value` = original value throughout
- The `RoutePolicy` call is a `STATICCALL` (read-only) from `CounterfactualDeposit`'s delegatecall context, so the policy sees the clone as `msg.sender`. The dispatcher passes `address(this)` (the clone) as the explicit `clone` argument so future implementations can vary the root per-clone without an interface change; the V1 implementation ignores it

### Clone Identity (`CloneArgs`)

Each clone's bytecode appends a single 32-byte immutable argument: `argsHash = keccak256(abi.encode(cloneArgs))` over five identity fields:

| Field                | Type      | Description                                                                                                              |
| -------------------- | --------- | ------------------------------------------------------------------------------------------------------------------------ |
| `outputToken`        | `bytes32` | Token received on the destination chain. `bytes32` to support non-EVM tokens.                                            |
| `destinationChainId` | `uint256` | Destination chain ID (or canonical Across-assigned ID for non-EVM destinations).                                         |
| `recipient`          | `bytes32` | Destination-chain address that receives `outputToken`.                                                                   |
| `admin`              | `address` | EVM address with full execution authority over the clone — can call any impl with any routeParams, bypassing the policy. |
| `routePolicyAddress` | `address` | The `RoutePolicy` proxy whose `activeRoot(clone)` authorizes this clone's routes.                                        |

The caller passes all five values in calldata at execute time; `CounterfactualDeposit` recomputes `keccak256(abi.encode(args))` and reverts on mismatch. After the check, `cloneArgs` is as authoritative as if stored in clone bytecode directly. Storing the 32-byte hash instead of the full ~140 bytes of unhashed args keeps clones cheap to deploy (~77 bytes total).

### Route Policy

Per-chain `RoutePolicy` proxies hold a merkle root over the routes a clone may execute on that chain. Each clone is bound at deploy time to a specific `routePolicyAddress` via `cloneArgs.routePolicyAddress`. Multiple clones can share a policy; multiple policies can coexist on the same chain (e.g. a canonical Across policy plus per-integrator policies).

The policy owner — typically a multisig — can replace the root in one transaction via `updateRoot(newRoot)`, upgrading every clone pointing at that policy. The clone address doesn't change; only the set of authorized routes evolves. The owner can also upgrade the policy implementation via `upgradeToAndCall(newImpl, data)` — e.g. to enable per-clone root overrides — without changing the proxy's address. Storage uses ERC-7201 namespaced layout so future implementations can add fields without colliding with the V1 storage.

Each chain's policy tree enumerates a **4-dimensional cross-product** of authorized routes:

- **`inputToken`** — token funding the clone on the source chain
- **`bridge`** — which impl handles the route (SpokePool, CCTP, OFT, etc.)
- **`destinationChainId`** — destination chain (also bound into the leaf preimage via `cloneArgs`)
- **`outputToken`** — token received on destination (also bound into the leaf preimage via `cloneArgs`)

Source chain is implicit — each chain has its own `RoutePolicy` proxy with its own per-chain root storage. A leaf committed to chain A's root cannot be proven against chain B's root.

### Leaf Format

Each leaf is computed as:

```
keccak256(bytes.concat(keccak256(abi.encode(
    implementation,
    outputToken,
    destinationChainId,
    keccak256(routeParams)
))))
```

The leaf preimage binds the clone's identity (`outputToken`, `destinationChainId`) so a leaf can only be proven against the clone it was authored for — no separate identity check needed. `routeParams` is itself pre-hashed because it's a variable-length bytes blob. The outer double-hash prevents leaf/internal-node ambiguity (OZ standard).

A single `RoutePolicy` tree typically holds many leaves (one per route). Multiple clones with the same `(outputToken, destinationChainId)` identity share authorized routes; clones with different identities prove against the same root but different leaves.

### Admin Escape

If `msg.sender == cloneArgs.admin`, `CounterfactualDeposit` skips the merkle proof entirely and delegatecalls whatever implementation the admin specified with whatever `routeParams` and `submitterData` they supplied. The admin has full execution authority over the clone, independent of policy state — withdraw works even when `activeRoot == bytes32(0)` or the policy contract is bricked. This is the structural guarantee that backs the bounded-trust property: the policy owner can govern routes for permissionless executors, but the clone's admin retains ultimate control over the clone's funds.

`WithdrawImplementation` additionally checks `msg.sender == admin` inside the impl, providing defense-in-depth against the off-chain footgun of accidentally including a withdraw leaf in a policy tree.

## CCTP Implementation (`CounterfactualDepositCCTP`)

| Variable                  | Source                   | Description                                                                  |
| ------------------------- | ------------------------ | ---------------------------------------------------------------------------- |
| `srcPeriphery`            | Constructor immutable    | `SponsoredCCTPSrcPeriphery` contract address                                 |
| `sourceDomain`            | Constructor immutable    | CCTP source domain ID for this chain                                         |
| `signer`                  | Constructor immutable    | Address that authorizes runtime `executionFee` via EIP-712                   |
| `destinationDomain`       | `routeParams`            | CCTP destination domain                                                      |
| `mintRecipient`           | `routeParams`            | DstPeriphery handler contract on destination                                 |
| `burnToken`               | `routeParams`            | Token to burn (e.g. USDC address as bytes32)                                 |
| `destinationCaller`       | `routeParams`            | Permissioned bot that calls `receiveMessage` on destination                  |
| `cctpMaxFeeBps`           | `routeParams`            | Max CCTP fee in bps (computed to `maxFee` at execution time)                 |
| `minFinalityThreshold`    | `routeParams`            | Minimum finality before CCTP attestation                                     |
| `maxBpsToSponsor`         | `routeParams`            | Max bps of amount the relayer can sponsor                                    |
| `maxUserSlippageBps`      | `routeParams`            | Slippage tolerance for fees on destination                                   |
| `destinationDex`          | `routeParams`            | DEX on HyperCore for swaps                                                   |
| `accountCreationMode`     | `routeParams`            | Standard (0) or FromUserFunds (1)                                            |
| `executionMode`           | `routeParams`            | DirectToCore (0), ArbitraryActionsToCore (1), ArbitraryActionsToEVM (2)      |
| `actionData`              | `routeParams`            | Encoded action data for arbitrary execution modes                            |
| `maxExecutionFee`         | `routeParams`            | Fixed-amount cap on the runtime `executionFee` the signer can authorize      |
| `finalRecipient`          | `cloneArgs.recipient`    | Ultimate receiver on destination chain                                       |
| `finalToken`              | `cloneArgs.outputToken`  | Token recipient receives on destination                                      |
| `amount`                  | `submitterData`          | Gross amount of burnToken (includes executionFee)                            |
| `executionFeeRecipient`   | `submitterData`          | Address that receives the execution fee                                      |
| `nonce`                   | `submitterData`          | Unique nonce for SponsoredCCTP replay protection                             |
| `cctpDeadline`            | `submitterData`          | Deadline for the SponsoredCCTP quote (validated by SrcPeriphery)             |
| `executionFee`            | `submitterData` (signed) | Runtime fee paid to relayer; bounded by `routeParams.maxExecutionFee`        |
| `signatureDeadline`       | `submitterData` (signed) | Timestamp after which the local signer's signature is no longer valid        |
| `peripherySignature`      | `submitterData`          | Signature from SponsoredCCTP quote signer (forwarded unchanged)              |
| `counterfactualSignature` | `submitterData`          | EIP-712 signature from local `signer` authorizing the runtime `executionFee` |

Two signatures are checked per execute:

1. **Local sig** (verified inside the impl): EIP-712 over `(nonce, executionFee, signatureDeadline)`. The clone is bound via the EIP-712 domain separator (`verifyingContract = address(this) = clone address`); `amount` is bound transitively via the periphery sig (which covers `depositAmount`); the route is bound transitively via `nonce`, which the periphery's quote signature also covers. Single-use replay protection comes free: once the periphery consumes the nonce, the local sig is unusable.
2. **Periphery sig** (verified by `SponsoredCCTPSrcPeriphery`): covers the full quote (destination, route fields, amount, nonce, deadline). Forwarded unchanged.

## OFT Implementation (`CounterfactualDepositOFT`)

| Variable                  | Source                   | Description                                                             |
| ------------------------- | ------------------------ | ----------------------------------------------------------------------- |
| `oftSrcPeriphery`         | Constructor immutable    | `SponsoredOFTSrcPeriphery` contract address                             |
| `srcEid`                  | Constructor immutable    | OFT source endpoint ID for this chain                                   |
| `signer`                  | Constructor immutable    | Address that authorizes runtime `executionFee` via EIP-712              |
| `dstEid`                  | `routeParams`            | OFT destination endpoint ID                                             |
| `destinationHandler`      | `routeParams`            | Composer contract on destination (OFT `to` param)                       |
| `token`                   | `routeParams`            | Local token address (the OFT token on source chain)                     |
| `maxOftFeeBps`            | `routeParams`            | Max OFT bridge fee in bps                                               |
| `lzReceiveGasLimit`       | `routeParams`            | Gas limit for `lzReceive` on destination                                |
| `lzComposeGasLimit`       | `routeParams`            | Gas limit for `lzCompose` on destination                                |
| `maxBpsToSponsor`         | `routeParams`            | Max bps of amount the relayer can sponsor                               |
| `maxUserSlippageBps`      | `routeParams`            | Slippage tolerance for swap on destination                              |
| `destinationDex`          | `routeParams`            | Destination DEX on HyperCore                                            |
| `accountCreationMode`     | `routeParams`            | Standard (0) or FromUserFunds (1)                                       |
| `executionMode`           | `routeParams`            | DirectToCore (0), ArbitraryActionsToCore (1), ArbitraryActionsToEVM (2) |
| `refundRecipient`         | `routeParams`            | LZ refund recipient for excess native messaging fees                    |
| `actionData`              | `routeParams`            | Encoded action data for arbitrary execution modes                       |
| `maxExecutionFee`         | `routeParams`            | Fixed-amount cap on the runtime `executionFee`                          |
| `finalRecipient`          | `cloneArgs.recipient`    | User address on destination                                             |
| `finalToken`              | `cloneArgs.outputToken`  | Final token user receives                                               |
| `amount`                  | `submitterData`          | Gross amount of token (includes executionFee)                           |
| `executionFeeRecipient`   | `submitterData`          | Address that receives the execution fee                                 |
| `nonce`                   | `submitterData`          | Unique nonce for SponsoredOFT replay protection                         |
| `oftDeadline`             | `submitterData`          | Deadline for the SponsoredOFT quote (validated by SrcPeriphery)         |
| `executionFee`            | `submitterData` (signed) | Runtime fee paid to relayer; bounded by `routeParams.maxExecutionFee`   |
| `signatureDeadline`       | `submitterData` (signed) | Timestamp after which the local signer's signature is no longer valid   |
| `peripherySignature`      | `submitterData`          | Signature from SponsoredOFT quote signer (forwarded unchanged)          |
| `counterfactualSignature` | `submitterData`          | EIP-712 signature from local `signer`                                   |
| `msg.value`               | Argument                 | Native ETH for LayerZero messaging fees                                 |

Same two-signature pattern as CCTP. `execute` is `payable` — `msg.value` covers LayerZero native messaging fees, forwarded to `SponsoredOFTSrcPeriphery.deposit{value: msg.value}()`. The relayer pays this and recoups via `executionFee`.

## SpokePool Implementation (`CounterfactualDepositSpokePool`)

| Variable                  | Source                         | Description                                                                      |
| ------------------------- | ------------------------------ | -------------------------------------------------------------------------------- |
| `spokePool`               | Constructor immutable          | Across SpokePool contract address                                                |
| `signer`                  | Constructor immutable          | Address that authorizes execution parameters via EIP-712                         |
| `wrappedNativeToken`      | Constructor immutable          | WETH address, substituted as inputToken for native deposits to SpokePool         |
| `inputToken`              | `routeParams`                  | Token deposited on source (as bytes32), or `NATIVE_ASSET` for native ETH         |
| `message`                 | `routeParams`                  | Arbitrary message forwarded to recipient                                         |
| `stableExchangeRate`      | `routeParams`                  | inputToken per outputToken exchange rate (1e18 scaled), used for fee calculation |
| `maxFeeFixed`             | `routeParams`                  | Max fixed fee component (in inputToken units), covers gas-like fixed costs       |
| `maxFeeBps`               | `routeParams`                  | Max variable fee component in basis points, scales with deposit size             |
| `destinationChainId`      | `cloneArgs.destinationChainId` | Across destination chain ID                                                      |
| `outputToken`             | `cloneArgs.outputToken`        | Token received on destination (as bytes32)                                       |
| `recipient`               | `cloneArgs.recipient`          | Recipient on destination                                                         |
| `inputAmount`             | `submitterData` (signed)       | Gross amount of inputToken (includes executionFee)                               |
| `outputAmount`            | `submitterData` (signed)       | Output amount passed to SpokePool                                                |
| `exclusiveRelayer`        | `submitterData` (signed)       | Optional exclusive relayer (bytes32(0) for none)                                 |
| `exclusivityDeadline`     | `submitterData` (signed)       | Seconds of relayer exclusivity (0 for none)                                      |
| `executionFeeRecipient`   | `submitterData`                | Address that receives the execution fee                                          |
| `quoteTimestamp`          | `submitterData` (signed)       | Quote timestamp from Across API (SpokePool validates recency)                    |
| `fillDeadline`            | `submitterData` (signed)       | Timestamp by which the deposit must be filled                                    |
| `signatureDeadline`       | `submitterData` (signed)       | Timestamp after which the signature is no longer valid                           |
| `executionFee`            | `submitterData` (signed)       | Runtime fee paid to relayer; bounded by the total-fee check                      |
| `counterfactualSignature` | `submitterData`                | EIP-712 signature from `signer` over signed arguments                            |

### EIP-712 Signature Verification

SpokePool verifies a single local signature itself (no periphery sits between it and `SpokePool.deposit()`). CCTP and OFT verify a local signature too, alongside the periphery's own quote signature — see their sections above.

- **Domain separator** uses OpenZeppelin's `EIP712` with `address(this)` (the clone address) — prevents cross-clone replay
- **Typehash**: `ExecuteDeposit(address clone, bytes32 routeParamsHash, uint256 inputAmount, uint256 outputAmount, bytes32 exclusiveRelayer, uint32 exclusivityDeadline, uint32 quoteTimestamp, uint32 fillDeadline, uint32 signatureDeadline, uint256 executionFee)`
  - `clone` and `routeParamsHash` together pin the signature to a specific clone + specific leaf, so it can't be reused across clones or across leaves within a policy.
- **Signer** is an immutable set at impl construction, shared across all clones

Unlike CCTP/OFT, SpokePool's typehash binds the full set of runtime fields (`inputAmount`, `outputAmount`, etc.) because there's no periphery quote covering them. The local signature is the only thing standing between the executor and arbitrary-parameter execution.

### Fee Check

The implementation enforces that the total fee (relayer + execution) doesn't exceed a combined fixed + variable cap:

```
outputInInputToken = outputAmount * stableExchangeRate / 1e18
relayerFee = depositAmount - outputInInputToken  (0 if negative)
totalFee = relayerFee + executionFee
maxFee = maxFeeFixed + (maxFeeBps * inputAmount) / 10000
if totalFee > maxFee:
    revert MaxFee
```

The two-component cap (`maxFeeFixed + maxFeeBps`) handles deposits of varying sizes. Fixed costs (origin/destination gas, execution fee) don't scale with amount, so a pure bps cap would be too restrictive for small deposits and too permissive for large ones. `maxFeeFixed` covers the fixed costs, `maxFeeBps` covers the relayer fee that scales with size.

`executionFee` is bounded implicitly by this same total-fee check — there's no separate `maxExecutionFee` field (in contrast to CCTP/OFT, which use one because they don't have an analogous total-fee gate).

**Assumption:** The `stableExchangeRate` route param is fixed at policy-authoring time, so this fee check assumes `inputToken` and `outputToken` are not volatile relative to each other (e.g. stablecoin pairs, or the same token on different chains). If the real market rate drifts significantly, the fee check may be too lenient or too strict.

### Depositor Field

The `depositor` parameter passed to `SpokePool.deposit()` is `address(this)` (the clone address). SpokePool refunds for expired deposits go back to the clone, where they can be re-executed or withdrawn.

**No depositor-driven speed-ups:** Because the depositor is the clone address (a contract with no private key), depositor-initiated `speedUpV3Deposit` calls are not possible. The depositor cannot produce the required signature to authorize speed-ups.

### Native ETH Deposits

When `inputToken` is set to `NATIVE_ASSET` (`0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE`) in the route params, users send native ETH to the predicted CREATE2 address instead of ERC20 tokens. At execution time, the clone detects native ETH by checking:

```
isNative = inputToken == NATIVE_ASSET
```

- **Native flow**: `wrappedNativeToken` is substituted as `inputToken` in the `spokePool.deposit{value: depositAmount}()` call so SpokePool recognizes and wraps the ETH. Execution fee paid in ETH via `.call{value}`.
- **ERC20 flow**: existing `forceApprove` + `deposit` path. Execution fee paid in ERC20 via `safeTransfer`.

The clone has a `receive()` function (in `CounterfactualDeposit`) to accept ETH before deployment (sent to the predicted address) and after deployment.

## Withdraw Implementation (`WithdrawImplementation`)

Standalone impl that conforms to `ICounterfactualImplementation` like any other. The clone-identity fields (`recipient`, `outputToken`, `destinationChainId`) and `routeParams` are accepted but ignored.

| Variable | Source                           | Description                                                          |
| -------- | -------------------------------- | -------------------------------------------------------------------- |
| `admin`  | `CounterfactualDeposit`-supplied | Clone admin from `cloneArgs.admin`; used for the internal auth check |
| `token`  | `submitterData`                  | Token to withdraw, or `NATIVE_ASSET` for ETH                         |
| `to`     | `submitterData`                  | Recipient address                                                    |
| `amount` | `submitterData`                  | Amount to withdraw                                                   |

The impl performs one check: `msg.sender == admin`. Reverts with `Unauthorized()` otherwise. Then decodes `(token, to, amount)` from `submitterData` and transfers (native via `.call{value}`, ERC20 via `_safeTransfer`).

Typical invocation flow: admin calls the clone's `execute(cloneArgs, withdrawImpl, "", abi.encode(token, to, amount), [])`. `CounterfactualDeposit` sees `msg.sender == cloneArgs.admin`, skips the merkle proof, and delegatecalls `WithdrawImplementation`. The impl's own admin check is defense-in-depth — even if a policy tree mistakenly included a withdraw leaf, a non-admin proof-path caller would be rejected by the impl.

## AdminWithdrawManager

A contract designed to be set as `cloneArgs.admin` for clones that want managed withdraw access (instead of an EOA admin). It exposes two withdrawal paths:

1. **`directWithdraw`** — only callable by `directWithdrawer` (a trusted operator address). The caller specifies `(token, to, amount)` and the manager invokes the clone's `execute` accordingly. The recipient is freely chosen.
2. **`signedWithdraw`** — callable by anyone with a valid EIP-712 signature from `signer`. The signed message commits a specific `(token, to, amount, deadline)` triple; the recipient is fixed by the signature, so the caller can't redirect.

EIP-712 typehash: `SignedWithdraw(address depositAddress,address token,address to,uint256 amount,uint256 deadline)`.

`owner` can update `directWithdrawer` and `signer`. The manager holds the canonical `withdrawImpl` address as an immutable, set at construction.

For either path, the call chain is `caller → AdminWithdrawManager → clone.execute(...) → CounterfactualDeposit → WithdrawImpl`. `CounterfactualDeposit`'s admin escape lets it through because `msg.sender == cloneArgs.admin` (= manager); the impl's own check passes because `msg.sender == admin` is still true under delegatecall.

## Tron Variants

Tron USDT's `transfer` function is non-standard: it moves balances correctly but always returns `false`, breaking `SafeERC20.safeTransfer` callers. The mainline `CounterfactualDepositSpokePool` and `WithdrawImplementation` inherit the virtual `_safeTransfer(token, to, amount)` hook from the shared `SafeTransferERC20` mixin (default: OZ `safeTransfer`). `CounterfactualDepositSpokePoolTr` and `WithdrawImplementationTron` inherit from their mainline counterparts and override only the hook to use `TronTransferLib._safeTransferBalanceCheck`, which detects success via a recipient balance-delta check and reverts with either `TronTransferCallReverted` (underlying call reverted) or `TronTransferBalanceMismatch` (call returned but balance delta != amount).

`forceApprove` is unaffected — `approve` returns `true` correctly on Tron USDT. The EIP-712 domain on `CounterfactualDepositSpokePoolTr` is inherited from the mainline; cross-implementation signature replay is already prevented by the `verifyingContract` field, since each clone's CREATE2 address depends on the implementation. Off-chain callers must pass the Tron-variant implementation address into `CounterfactualDepositFactoryTron.deploy(...)` for any USDT TRC20 flow — clone addresses change with the implementation.

`CounterfactualDepositOFT` and `CounterfactualDepositCCTP` are unchanged — Tron OFT routes bridge USDT0 (LayerZero's standard OFT contract) and CCTP is USDC-only by design; both are compliant ERC20s.

## Key Design Decisions

### 1. Persistent, Evolvable Addresses

**A clone's address is keyed solely to its five `CloneArgs` identity fields; the set of routes it can execute lives in the bound `RoutePolicy` and can evolve.**

Why: Users save a deposit address once and reuse it indefinitely, even as Across adds support for new bridges, chains, or routes. Upgrades to the policy don't invalidate addresses; they're a single transaction per chain.

### 2. Generic Factory

**The factory is bridge-agnostic — it takes a `CloneArgs` struct and a salt.**

Why: The factory hashes the args into a 32-byte `argsHash` and uses that as the clone's immutable arg. Adding a new bridge type requires only a new implementation contract — no factory changes. `deployAndExecute` and `execute` are `payable` to support bridges that need `msg.value` (e.g. OFT for LayerZero fees).

### 3. Hash-Only Immutable Args

**Each clone stores only `argsHash` (32 bytes), not the unhashed five fields.**

[EIP-1167](https://eips.ethereum.org/EIPS/eip-1167) defines a 45-byte minimal proxy. OpenZeppelin's `Clones.cloneDeterministicWithImmutableArgs` appends arbitrary bytes after the proxy bytecode. Storing the 32-byte `argsHash` keeps the clone at ~77 bytes total. Storing the full ~140 bytes of unhashed args would inflate every clone's deployment. `CounterfactualDeposit` recomputes the hash from caller-supplied fields on every execute and reverts on mismatch — once it matches, the args are as authoritative as if stored in clone bytecode.

### 4. Identity-Bound Leaf Format

**`destinationChainId` and `outputToken` are bound into the leaf preimage via `cloneArgs`, not duplicated in `routeParams`.**

The leaf is `keccak256(bytes.concat(keccak256(abi.encode(impl, outputToken, destChainId, keccak256(routeParams)))))`. A leaf authored for clone A's identity can't be proven against clone B with a different identity — no separate identity check needed. This also means impl-specific structs (`SpokePoolRouteParams`, `CCTPRouteParams`, `OFTRouteParams`) don't carry duplicated `outputToken`/`destinationChainId` fields.

### 5. Admin Escape

**`msg.sender == cloneArgs.admin` bypasses the merkle proof entirely.**

The admin can call any implementation with any `routeParams`, regardless of policy state. This guarantees fund recovery even if the policy contract is bricked, its root is `bytes32(0)`, or the policy owner is compromised. It's the structural backstop behind the bounded-trust property: the policy owner governs routes for permissionless executors; the admin retains ultimate control.

### 6. Per-Chain Policy

**One `RoutePolicy` per chain, deployed at the same address on every EVM chain.**

Two deterministic deploys land at the same address everywhere: (a) the `RoutePolicy` implementation (no constructor args), then (b) an `ERC1967Proxy` pointing at the implementation with init data `abi.encodeCall(RoutePolicy.initialize, (deployerEOA, bytes32(0)))`. Both go through the deterministic-deployment proxy. Ownership is transferred to the chain-local multisig as a post-deploy step. Each chain's root is independent — adding a new source chain doesn't impact any other chain's policy.

### 7. Dynamic Execution Fee, Hard-Capped per Leaf

**`executionFee` is supplied at execute time and authorized by a local signer, but bounded by a per-leaf cap committed in the merkle tree.**

Why: Gas costs and relayer competition move with market conditions; the fee can't be committed at policy-authoring time. The signer adjusts dynamically. To make signer compromise non-catastrophic, every route caps the fee:

- **CCTP/OFT** — explicit `maxExecutionFee` field in `routeParams`.
- **SpokePool** — `maxFeeFixed + maxFeeBps × inputAmount` cap on the combined `relayerFee + executionFee`, which implicitly bounds `executionFee` (no separate field needed).

### 8. Signature Verification: SpokePool vs CCTP/OFT

**SpokePool verifies its own EIP-712 signature; CCTP/OFT use both a local sig and a periphery sig.**

SpokePool calls `SpokePool.deposit()` directly, which doesn't validate quotes — without the local sig, anyone could execute with a manipulated `outputAmount` or `fillDeadline`. The local sig binds `clone + routeParamsHash + runtime fields` to prevent that.

CCTP/OFT forward to a `SrcPeriphery` that already validates a periphery-issued quote signature. The local sig is added on top to authorize the runtime `executionFee` (which the periphery doesn't see). It binds `(nonce, executionFee, signatureDeadline)`; the periphery sig binds the route + nonce + amount. Together they pin the execution. Nonce binding also gives single-use replay protection for free — once the periphery consumes the nonce, the local sig is unusable.

### 9. Address Reusability

**The same clone proxy can receive and execute multiple deposits over time.**

For subsequent deposits, callers can call the clone directly or use `factory.execute()`. `deployAndExecute()` reverts if the clone already exists; `deployIfNeededAndExecute()` skips deployment if the clone is already deployed (checked via `code.length`), making it safe to call regardless of deployment state.

### 10. Immutable Distribution (Gas Optimization)

**Chain-wide constants (srcPeriphery, sourceDomain, spokePool, signer) are immutable in the implementation, not the clone.**

These values are identical across all clones on a chain. Storing them in each clone wastes gas. The clone only stores the 32-byte `argsHash`. Chain-wide constants live in the implementation's bytecode and are accessible directly since EIP-1167 proxies use delegatecall.

## Deployment

Deploys all contracts via the [deterministic deployment proxy](https://github.com/Arachnid/deterministic-deployment-proxy) (`0x4e59b44847b379578588920cA78FbF26c0B4956C`), available on all EVM chains. CREATE2 addresses depend on `(factory, salt, initCode)` — contracts with identical initCode get the same address everywhere. No fresh EOA, nonce ordering, or nonce burning required. Already-deployed contracts are auto-skipped.

### Contracts

| Index | Contract                         | Same address across chains?                                   |
| ----- | -------------------------------- | ------------------------------------------------------------- |
| 0     | `CounterfactualDeposit`          | Yes (no constructor args)                                     |
| 1     | `CounterfactualDepositFactory`   | Yes (no constructor args)                                     |
| 2     | `WithdrawImplementation`         | Yes (no constructor args)                                     |
| 3     | `RoutePolicy` (impl + proxy)     | Yes (impl: no args; proxy: identical init data across chains) |
| 4     | `CounterfactualDepositSpokePool` | No (chain-specific constructor args)                          |
| 5     | `CounterfactualDepositCCTP`      | No (chain-specific constructor args)                          |
| 6     | `CounterfactualDepositOFT`       | No (chain-specific constructor args)                          |
| 7     | `AdminWithdrawManager`           | Yes (deployer as owner/directWithdrawer, signer from config)  |

`RoutePolicy` is deployed as an implementation + `ERC1967Proxy` pair; the proxy is initialized with a deployer EOA as initial owner and `bytes32(0)` as initial root. As a per-chain post-deploy step, the deployer EOA calls `transferOwnership(chainLocalMultisig)` on the proxy, then the multisig calls `updateRoot(realRoot)` to activate the policy. Until that point the policy is unusable for non-admin executors (no proof verifies against a zero root), but admin escapes work regardless.

### Configuration

`script/counterfactual/config.toml` (per chain):

```toml
[1]
[1.address]
signer = "0x..."
ownerAndDirectWithdrawer = "0x..."

[42161]
[42161.address]
signer = "0x..."
ownerAndDirectWithdrawer = "0x..."
```

- `signer` — signer address for `AdminWithdrawManager` and `CounterfactualDepositSpokePool` (used in constructor / transferred post-deploy)
- `ownerAndDirectWithdrawer` — address that receives both owner and directWithdrawer roles on `AdminWithdrawManager`; also the chain-local multisig that receives `RoutePolicy` ownership
- Chain-specific params (`spokePool`, `wrappedNativeToken`, `cctpPeriphery`, `cctpDomain`, `oftPeriphery`, `oftEid`) are auto-resolved from `generated/constants.json` and `broadcast/deployed-addresses.json`

### Deploying

1. **Fund the deployer** on the target chain with enough ETH for gas.
2. **Simulate** (deploy all including SpokePool, CCTP, and OFT):

   ```bash
   source .env
   FOUNDRY_PROFILE=counterfactual forge script \
     script/counterfactual/DeployAllCounterfactual.s.sol:DeployAllCounterfactual \
     --sig "run(string,bool,bool,bool,bool,bool)" $RPC_URL true true true true false \
     --rpc-url $RPC_URL -vvvv
   ```

   Arguments: `rpcUrl`, `deploySpokePool`, `deployCctp`, `deployOft`, `transferRoles`, `broadcast`.

3. **Deploy** (set `broadcast` to `true` and add `--ffi`):

   ```bash
   FOUNDRY_PROFILE=counterfactual forge script \
     script/counterfactual/DeployAllCounterfactual.s.sol:DeployAllCounterfactual \
     --sig "run(string,bool,bool,bool,bool,bool)" $RPC_URL true true true true true \
     --rpc-url $RPC_URL --ffi -vvvv
   ```

### AdminWithdrawManager Role Transfer

The `AdminWithdrawManager` is deployed with the deployer as owner and directWithdrawer, and the signer from `config.toml` (all global, ensuring the same CREATE2 address on every chain). After all deployments complete, if `transferRoles` is `true`, `DeployAllCounterfactual` transfers directWithdrawer first, verifies it succeeded, then transfers ownership to the chain-specific `ownerAndDirectWithdrawer` address from `config.toml`. If the directWithdrawer transfer fails, ownership transfer is skipped to avoid losing access.

### Important

- Any funded address can deploy. No ordering constraints. Already-deployed contracts are auto-skipped.
- Individual deploy scripts can also be run standalone.

## Security Model

- **RoutePolicy Owner**: Multisig that controls both the merkle root and the policy implementation (V1 collapses both into `onlyOwner`). Can replace the root or upgrade the impl in one transaction, affecting every clone pointing at the policy. Cannot redirect destination, output token, or recipient — those are clone immutables. The admin escape protects fund recovery if the owner is compromised, the impl is upgraded maliciously, or the policy is bricked.
- **Clone `admin`**: Address with full execution authority over the clone, bypassing the policy. Typically `AdminWithdrawManager`, but can be an EOA, multisig, or `TimelockController` for trust-minimized setups.
- **SponsoredCCTP/OFT Signer**: Trusted address that signs bridge quotes. Compromise allows bad quotes but fees are bounded by user-set `cctpMaxFeeBps`/`maxOftFeeBps` plus the per-leaf `maxExecutionFee`.
- **SpokePool Signer**: Signs runtime execution parameters for SpokePool calls. Compromise allows bad `outputAmount` values but bounded by the `maxFeeFixed + maxFeeBps` total-fee cap.
- **Execution Fee**: Dynamic per-execute, signed by the impl's local signer. Capped per leaf — by `maxExecutionFee` (CCTP/OFT) or by the total-fee check (SpokePool).
- **Nonce/Deadline (CCTP/OFT)**: Protocol-specific deadlines and nonces are validated by SrcPeriphery; the local sig also binds the nonce, giving single-use replay protection for free.
- **SignatureDeadline (SpokePool)**: Bounded replay window; token balance consumption provides natural protection between deadlines.
- **Cross-clone replay**: Prevented by the EIP-712 domain separator's `verifyingContract` field (= clone address during delegatecall).
- **Merkle proof**: Each non-admin `execute` call verifies inclusion against `IRoutePolicy(cloneArgs.routePolicyAddress).activeRoot(address(this))`. The leaf preimage binds the clone's `(outputToken, destinationChainId)` identity, so a leaf authored for one clone can't be proven against another.

### AdminWithdrawManager

Provides two withdrawal paths for clones that set it as `admin`:

1. **Direct withdraw** (`directWithdraw`) — A trusted `directWithdrawer` address calls the manager with `(depositAddress, cloneArgs, token, to, amount)`. The manager invokes the clone's execute; the admin escape lets it through because the manager IS the admin.
2. **Signed withdraw** (`signedWithdraw`) — Anyone with a valid EIP-712 signature from `signer` can trigger a withdrawal. The recipient is fixed by the signed message (`SignedWithdraw(address depositAddress,address token,address to,uint256 amount,uint256 deadline)`), so the caller cannot redirect.

The `owner` can update `directWithdrawer` and `signer` addresses.

### Trust-Minimized Admin via TimelockController

Setting `cloneArgs.admin` to an OpenZeppelin `TimelockController` adds a time delay to all admin actions on the clone, giving users a window to react. No contract changes needed — the TimelockController address is simply set as `admin` at clone-deploy time.
