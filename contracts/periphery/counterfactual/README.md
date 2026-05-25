# Counterfactual Deposit Addresses

Gas-optimized system for creating persistent, reusable deposit addresses via deterministic CREATE2 deployment. Supports multiple bridge types: **CCTP**, **OFT** (LayerZero), and **SpokePool** (Across). Routes are authorized by a per-chain `RoutePolicy` whose merkle root the owner can update — so the set of supported routes can evolve without invalidating clone addresses.

## Architecture

**Generic factory + identity-bound clone + per-chain RoutePolicy + bridge-specific implementations:**

- `CounterfactualDepositFactory` — Bridge-agnostic factory. Deploys clones of `CounterfactualDeposit` deterministically via `Clones.cloneDeterministicWithImmutableArgs`, predicts addresses, and forwards raw calldata to clones. Takes the five `CloneArgs` identity fields as input.
- `CounterfactualDeposit` — Merkle-dispatched execution entrypoint. All clones are EIP-1167 proxies of this contract. The clone's sole immutable arg is `argsHash = keccak256(abi.encode(cloneArgs))` over the five identity fields. On execute, `CounterfactualDeposit` verifies the hash, either bypasses the policy (user escape — `msg.sender == cloneArgs.userAddress`) or verifies the merkle proof against `IRoutePolicy(cloneArgs.routePolicyAddress).activeRoot(address(this))`, then delegatecalls the implementation.
- `RoutePolicyImmutableRoot` — UUPS-upgradeable, `Ownable` `IRoutePolicy` implementation. The active merkle root is `immutable` on the implementation contract (baked into runtime bytecode) — `activeRoot` reads it directly, with no `SLOAD`. Rotating the root is a UUPS upgrade: the owner deploys a new implementation with the new root in its constructor and calls `upgradeToAndCall(newImpl, "")` on the proxy. The proxy's address is unchanged across rotations. Deployed at the same address on every EVM chain at genesis; each chain rotates independently after that.
- `CounterfactualDepositSpokePool` — Deposit implementation for Across SpokePool. Verifies an EIP-712 signature itself (since it calls `SpokePool.deposit()` directly) and enforces a `maxFeeFixed + maxFeeBps × inputAmount` total-fee cap.
- `CounterfactualDepositCCTP` — Deposit implementation for SponsoredCCTP. Verifies a local EIP-712 signature authorizing the runtime `executionFee`, then forwards a `SponsoredCCTPQuote` to `SponsoredCCTPSrcPeriphery.depositForBurn()` along with the periphery's own quote signature.
- `CounterfactualDepositOFT` — Deposit implementation for SponsoredOFT (LayerZero). Same shape as CCTP plus `msg.value` forwarding for LZ native messaging fees.
- `WithdrawImplementation` — Withdraw implementation. Conforms to `ICounterfactualImplementation` like any other impl. The withdrawal destination is always `cloneArgs.userAddress` — fixed by clone identity, not chosen at execute time. Authorized callers are either the impl's immutable `admin` (typically an `AdminWithdrawManager`) or the clone's `userAddress`. Either path goes through `CounterfactualDeposit` — the user via the user escape, the impl `admin` via a merkle proof against a policy tree that includes the withdraw leaf.
- `AdminWithdrawManager` — Contract designed to be set as the immutable `admin` on a `WithdrawImplementation` to gate manager-driven withdrawals. Provides two paths: (1) direct withdraw by a trusted `directWithdrawer` and (2) signed withdraw by anyone with a valid EIP-712 signature from `signer`. Neither path chooses recipient — funds always land at `cloneArgs.userAddress`. A compromised `directWithdrawer` or `signer` can force a withdrawal to happen but cannot redirect it.
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
│     userAddress, routePolicyAddress))                        │
└──────────────────────────────────────────────────────────────┘
       │
       │ DELEGATECALL (via EIP-1167)
       ▼
┌──────────────────────────────────────────────────────────────┐                ┌──────────────────────────────────────────┐
│ CounterfactualDeposit (no per-clone state)                   │                │ RoutePolicyImmutableRoot (UUPS proxy)    │
│   1. verifies keccak256(args) == clone.argsHash              │   staticcall   │   - owner: Across or integrator multisig │
│   2. if msg.sender == args.userAddress: skip merkle check    │ ─────────────► │   - root: immutable on the impl, baked   │
│      else: verify merkle proof against policy root           │ activeRoot     │     into runtime bytecode (no SLOAD)     │
│   3. delegatecall impl with verified args                    │ (address(this))│   - rotate via upgradeToAndCall to a new │
│                                                              │ ◄───────── b32 │     impl carrying the new root           │
└──────────────────────────────────────────────────────────────┘                └──────────────────────────────────────────┘
       │
       │ DELEGATECALL
       ▼
┌──────────────────────────────────────────────────────────────┐
│ Implementation.execute(                                      │
│   recipient, outputToken, destinationChainId,                │
│   userAddress, routeParams, submitterData)                   │
│                                                              │
│ - CCTP / OFT / SpokePool: verify signer EIP-712 over runtime │
│ - WithdrawImpl: msg.sender ∈ {admin, userAddress}            │
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

| Field                | Type      | Description                                                                                                                                                                                                                                                                                         |
| -------------------- | --------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `outputToken`        | `bytes32` | Token received on the destination chain. `bytes32` to support non-EVM tokens.                                                                                                                                                                                                                       |
| `destinationChainId` | `uint256` | Destination chain ID (or canonical Across-assigned ID for non-EVM destinations).                                                                                                                                                                                                                    |
| `recipient`          | `bytes32` | Destination-chain address that receives `outputToken`.                                                                                                                                                                                                                                              |
| `userAddress`        | `address` | EVM address representing the clone's user. The canonical authority — can call any impl with any routeParams via the dispatcher's user escape, bypassing the policy. Also the sole destination for `WithdrawImplementation` payouts: a compromised manager / signer cannot redirect funds elsewhere. |
| `routePolicyAddress` | `address` | The `RoutePolicy` proxy whose `activeRoot(clone)` authorizes this clone's routes.                                                                                                                                                                                                                   |

The caller passes all five values in calldata at execute time; `CounterfactualDeposit` recomputes `keccak256(abi.encode(args))` and reverts on mismatch. After the check, `cloneArgs` is as authoritative as if stored in clone bytecode directly. Storing the 32-byte hash instead of the full ~140 bytes of unhashed args keeps clones cheap to deploy (~77 bytes total).

### Route Policy

Per-chain `RoutePolicyImmutableRoot` proxies expose a merkle root over the routes a clone may execute on that chain. Each clone is bound at deploy time to a specific `routePolicyAddress` via `cloneArgs.routePolicyAddress`. Multiple clones can share a policy; multiple policies can coexist on the same chain (e.g. a canonical Across policy plus per-integrator policies).

The root itself is `immutable` on the implementation contract — baked into the runtime bytecode at construction time, not stored. `activeRoot(clone)` returns it directly with no `SLOAD`. To rotate the root, the policy owner — typically a multisig — deploys a new implementation carrying the new root in its constructor and calls `upgradeToAndCall(newImpl, "")` on the proxy. The proxy's address is unchanged across rotations; only the ERC-1967 implementation slot moves. Off-chain indexers can watch the standard `Upgraded(address)` event and read `activeRoot(...)` to learn the new root.

Each chain's policy tree enumerates authorized route shapes. What dimensions a leaf binds depends on the implementation it targets:

- **`inputToken`** — token funding the clone on the source chain (always bound, inside `routeParams`)
- **`bridge`** — which impl handles the route (SpokePool, CCTP, OFT, etc.) — always bound (the leaf commits `implementation`)
- **`outputToken`** — token received on destination (bound only for identity-binding impls; see below)
- **`destinationChainId`** — destination chain (bound only for identity-binding impls; see below)

Source chain is implicit — each chain has its own `RoutePolicyImmutableRoot` proxy carrying its own root (via its current implementation's `immutable`). A leaf committed to chain A's root cannot be proven against chain B's root.

### Leaf Format

Each leaf is computed as:

```
keccak256(bytes.concat(keccak256(abi.encode(
    implementation,
    keccak256(routeParams)
))))
```

The dispatcher is **agnostic to clone identity at the leaf level**. `cloneArgs.outputToken` and `cloneArgs.destinationChainId` are forwarded to the implementation but **not** committed to the leaf preimage. `routeParams` is itself pre-hashed because it's a variable-length bytes blob. The outer double-hash prevents leaf/internal-node ambiguity (OZ standard).

Implementations that need to bind a leaf to a specific clone identity declare so by committing the binding fields inside their `routeParams` struct and verifying them at execute time via `CloneIdentity.enforce(...)`:

| Impl                             | Identity binding                                                                                                    | Why                                                                                                                                                                                        |
| -------------------------------- | ------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `CounterfactualDepositSpokePool` | Bound — `outputToken` and `destinationChainId` in `SpokePoolRouteParams`, checked via `CloneIdentity.enforce(...)`. | `stableExchangeRate` is a per-pair assumption (input↔output). A leaf authored for one pair would produce an incorrect fee bound if executed against a clone with a different output token. |
| `CounterfactualDepositCCTP`      | Bound — same pattern.                                                                                               | The destination periphery routes directly to the bound output token; no refund path for infeasible routes.                                                                                 |
| `CounterfactualDepositOFT`       | Bound — same pattern.                                                                                               | Same reasoning as CCTP.                                                                                                                                                                    |
| `WithdrawImplementation`         | N/A — gated by `msg.sender ∈ {admin, userAddress}` inside the impl, not by route params.                            | Auth lives in the impl's caller check, not in policy authorization.                                                                                                                        |

All current production impls bind identity, so the practical leaf cardinality matches the per-pair cross-product. The architecture leaves room for future agnostic impls — an impl that doesn't include the binding fields in its `routeParams` and doesn't call `CloneIdentity.enforce(...)` is free to be agnostic — but no current impl exercises that option.

A single policy's tree typically holds many leaves (one per route). Multiple clones with the same `(outputToken, destinationChainId)` identity share authorized routes; clones with different identities prove against the same root but different leaves.

### User Escape

If `msg.sender == cloneArgs.userAddress`, `CounterfactualDeposit` skips the merkle proof entirely and delegatecalls whatever implementation the user specified with whatever `routeParams` and `submitterData` they supplied. The user has full execution authority over their own clone, independent of policy state — withdraw works even when `activeRoot == bytes32(0)` or the policy contract is bricked. This is the structural guarantee that backs the bounded-trust property: the policy owner governs routes for permissionless executors; the user retains ultimate control over the clone's funds.

`WithdrawImplementation` additionally checks `msg.sender ∈ {admin, userAddress}` inside the impl. This serves two purposes: (a) it lets the impl's immutable `admin` (typically `AdminWithdrawManager`) trigger withdrawals via the merkle path while still forcing the recipient to `userAddress`, and (b) it provides defense-in-depth — random callers proving a withdraw leaf still get rejected.

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

Standalone impl that conforms to `ICounterfactualImplementation` like any other. The clone-identity fields `recipient`, `outputToken`, `destinationChainId` and `routeParams` are accepted but ignored; the impl uses `userAddress` (forwarded from `cloneArgs.userAddress`) as the forced withdrawal destination.

| Variable      | Source                           | Description                                                                                                             |
| ------------- | -------------------------------- | ----------------------------------------------------------------------------------------------------------------------- |
| `admin`       | Contract-level immutable         | Address authorized to trigger withdrawals in addition to `userAddress`. Typically the canonical `AdminWithdrawManager`. |
| `userAddress` | `CounterfactualDeposit`-supplied | Clone's user, from `cloneArgs.userAddress`. Both the forced destination and one of two authorized callers.              |
| `token`       | `submitterData`                  | Token to withdraw, or `NATIVE_ASSET` for ETH                                                                            |
| `amount`      | `submitterData`                  | Amount to withdraw                                                                                                      |

The impl performs one check: `msg.sender ∈ {admin, userAddress}`. Reverts with `Unauthorized()` otherwise. Then decodes `(token, amount)` from `submitterData` and transfers to `userAddress` (native via `.call{value}`, ERC20 via `_safeTransfer`).

Two typical invocation paths:

1. **User self-withdraw** — the user calls `clone.execute(cloneArgs, withdrawImpl, "", abi.encode(token, amount), [])`. The dispatcher sees `msg.sender == cloneArgs.userAddress`, skips the merkle proof, and delegatecalls the impl. The impl's caller check passes because `msg.sender == userAddress`. Works under any policy state, including when the policy is bricked.
2. **Manager-driven withdraw** — the immutable `admin` (typically `AdminWithdrawManager`) calls `clone.execute(cloneArgs, withdrawImpl, "", abi.encode(token, amount), proof)`. The dispatcher sees `msg.sender != userAddress`, hits the merkle path, and verifies the proof against a policy that includes the withdraw leaf. The impl's caller check passes because `msg.sender == admin`. Recipient is still `userAddress` regardless.

## AdminWithdrawManager

A contract designed to be set as the `WithdrawImplementation`'s immutable `admin`. It gates manager-driven withdrawals; the destination is fixed by the clone's `userAddress`, so neither the manager nor its `directWithdrawer` / `signer` can choose recipient. It exposes two withdrawal paths:

1. **`directWithdraw`** — only callable by `directWithdrawer` (a trusted operator address). The caller specifies `(token, amount)` and supplies the merkle proof for the policy's withdraw leaf. The manager invokes the clone's `execute` accordingly. Recipient is `cloneArgs.userAddress`.
2. **`signedWithdraw`** — callable by anyone with a valid EIP-712 signature from `signer`. The signed message commits `(depositAddress, token, amount, deadline)` — recipient is not part of the signature because it's fixed by clone identity. The submitter supplies the merkle proof (the policy tree is publicly known off-chain).

EIP-712 typehash: `SignedWithdraw(address depositAddress,address withdrawImpl,address token,uint256 amount,uint256 deadline)`.

`owner` can update `directWithdrawer` and `signer`. The target `withdrawImpl` is supplied per call — the manager has no immutable impl reference. This breaks what would otherwise be a circular construction dependency (impl needs manager address for its immutable `admin`; manager would otherwise need impl address for its immutable `withdrawImpl`). Deployment is straightforward: deploy the manager first, then deploy `WithdrawImplementation(managerAddress)`. Both are deterministic across chains via Nick's factory with no prediction logic required. The signer's typehash commits to `withdrawImpl` so a submitter cannot redirect an authorized withdrawal to a different impl; the dispatcher's merkle check independently restricts which impls are reachable for a given clone.

For either path, the call chain is `caller → AdminWithdrawManager → clone.execute(...) → CounterfactualDeposit → WithdrawImpl`. The dispatcher checks the merkle proof (manager isn't `userAddress`); the impl's caller check passes because `msg.sender == admin` (= manager); funds always land at `userAddress`.

**Trust model.** `directWithdrawer` and `signer` are "hot" roles in practice — they authorize withdrawals. A compromised key in either role can force a withdrawal to happen at an inconvenient time but cannot redirect funds. The user receives their own money in their own wallet.

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

### 4. Impl-Declared Identity Binding

**The dispatcher's leaf commits only `(implementation, keccak256(routeParams))`. Each impl declares its own identity-binding semantics by what it puts in `routeParams`.**

The leaf is `keccak256(bytes.concat(keccak256(abi.encode(impl, keccak256(routeParams)))))` — agnostic to `outputToken` and `destinationChainId`. Implementations that need to bind a leaf to a specific clone identity commit `outputToken` and `destinationChainId` inside their `routeParams` struct and verify them via `CloneIdentity.enforce(...)` at the top of `execute`.

All three production impls (`CounterfactualDepositSpokePool`, `CounterfactualDepositCCTP`, `CounterfactualDepositOFT`) currently bind, each for its own reason — SpokePool because `stableExchangeRate` is a per-pair assumption, CCTP and OFT because their destination peripheries route directly to the bound output token with no refund path. The architecture leaves the door open for a future agnostic impl (whose `routeParams` would omit the binding fields and skip the `CloneIdentity.enforce(...)` call), but no current impl exercises that option.

Why this structure rather than baking binding into the dispatcher: each impl can declare its own binding semantics, making the audit story local. A future variant that's safe to be agnostic — or one with different binding requirements — doesn't require dispatcher changes.

### 5. User Escape

**`msg.sender == cloneArgs.userAddress` bypasses the merkle proof entirely.**

The user can call any implementation with any `routeParams`, regardless of policy state. This guarantees fund recovery even if the policy contract is bricked, its root is `bytes32(0)`, or the policy owner is compromised. It's the structural backstop behind the bounded-trust property: the policy owner governs routes for permissionless executors; the user retains ultimate control over their own clone.

The `userAddress` field is also the forced destination for `WithdrawImplementation`. That tie — "the user is both the escape authority and the only valid withdraw destination" — is what lets `AdminWithdrawManager`'s `directWithdrawer` and `signer` roles be "hot" without being able to redirect funds. The worst a compromised manager role can do is force the user to receive their own money.

### 6. Per-Chain Policy

**One `RoutePolicyImmutableRoot` per chain, deployed at the same address on every EVM chain at genesis.**

Two deterministic deploys land at the same address everywhere as long as their inputs are identical across chains: (a) the implementation, deployed with constructor arg `bytes32(0)` (the day-0 sentinel root); (b) an `ERC1967Proxy` pointing at that implementation with init data `abi.encodeCall(RoutePolicyImmutableRoot.initialize, (deployerEOA))`. Both go through the deterministic-deployment proxy. Ownership is transferred to the chain-local multisig as a post-deploy step. After that, each chain rotates independently: the chain-local multisig deploys a new implementation carrying its real root and calls `upgradeToAndCall(newImpl, "")` on the proxy. The proxy's address is locked in at genesis and never changes.

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

| Index | Contract                                  | Same address across chains?                                                               |
| ----- | ----------------------------------------- | ----------------------------------------------------------------------------------------- |
| 0     | `CounterfactualDeposit`                   | Yes (no constructor args)                                                                 |
| 1     | `CounterfactualDepositFactory`            | Yes (no constructor args)                                                                 |
| 2     | `WithdrawImplementation`                  | Yes (no constructor args)                                                                 |
| 3     | `RoutePolicyImmutableRoot` (impl + proxy) | Yes (impl: identical `bytes32(0)` constructor arg at genesis; proxy: identical init data) |
| 4     | `CounterfactualDepositSpokePool`          | No (chain-specific constructor args)                                                      |
| 5     | `CounterfactualDepositCCTP`               | No (chain-specific constructor args)                                                      |
| 6     | `CounterfactualDepositOFT`                | No (chain-specific constructor args)                                                      |
| 7     | `AdminWithdrawManager`                    | Yes (deployer as owner/directWithdrawer, signer from config)                              |

`RoutePolicyImmutableRoot` is deployed as an implementation + `ERC1967Proxy` pair. The day-0 implementation is constructed with `bytes32(0)` as the root (identical across chains, so the impl and proxy both land at the same address everywhere via the deterministic-deployment proxy); the proxy's `initialize(deployerEOA)` sets the deployer EOA as initial owner. As a per-chain post-deploy step, the deployer EOA calls `transferOwnership(chainLocalMultisig)` on the proxy. The multisig then activates the policy by deploying a new implementation carrying the real root and calling `upgradeToAndCall(newImpl, "")`. Until that rotation happens the policy is unusable for non-user executors (no proof verifies against a zero root), but the user escape works regardless.

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

- **RoutePolicy Owner**: Multisig that controls the policy implementation (and therefore the root, since the root is `immutable` on the impl). Every root rotation is an `upgradeToAndCall` — the owner deploys a new impl and points the proxy at it. The owner can also upgrade to any other implementation (e.g. one with arbitrary `activeRoot` logic), so this is a meaningful trust grant. Cannot redirect destination, output token, or recipient — those are clone immutables. The user escape protects fund recovery if the owner is compromised, an arbitrary impl is installed, or the policy is bricked.
- **Clone `userAddress`**: The user's wallet. The structural authority over the clone — can call any impl bypassing the policy (user escape) and is the forced destination for `WithdrawImplementation`. Normally an EOA; can be a smart-contract wallet or `TimelockController` for trust-minimized setups.
- **`WithdrawImplementation` immutable `admin`**: Contract-level (one per `WithdrawImplementation` deployment), typically `AdminWithdrawManager`. Authorizes manager-driven withdrawals via the merkle path. Cannot choose recipient.
- **SponsoredCCTP/OFT Signer**: Trusted address that signs bridge quotes. Compromise allows bad quotes but fees are bounded by user-set `cctpMaxFeeBps`/`maxOftFeeBps` plus the per-leaf `maxExecutionFee`.
- **SpokePool Signer**: Signs runtime execution parameters for SpokePool calls. Compromise allows bad `outputAmount` values but bounded by the `maxFeeFixed + maxFeeBps` total-fee cap.
- **Execution Fee**: Dynamic per-execute, signed by the impl's local signer. Capped per leaf — by `maxExecutionFee` (CCTP/OFT) or by the total-fee check (SpokePool).
- **Nonce/Deadline (CCTP/OFT)**: Protocol-specific deadlines and nonces are validated by SrcPeriphery; the local sig also binds the nonce, giving single-use replay protection for free.
- **SignatureDeadline (SpokePool)**: Bounded replay window; token balance consumption provides natural protection between deadlines.
- **Cross-clone replay**: Prevented by the EIP-712 domain separator's `verifyingContract` field (= clone address during delegatecall).
- **Merkle proof**: Each non-user `execute` call verifies inclusion against `IRoutePolicy(cloneArgs.routePolicyAddress).activeRoot(address(this))`. The leaf commits `(implementation, keccak256(routeParams))`; per-impl identity binding via `CloneIdentity.enforce(...)` ensures a leaf authored for one clone can't be executed against another.

### AdminWithdrawManager

Provides two withdrawal paths gated by a `WithdrawImplementation` whose immutable `admin` is the manager. Funds always land at `cloneArgs.userAddress`; neither path can redirect.

1. **Direct withdraw** (`directWithdraw`) — A trusted `directWithdrawer` address calls the manager with `(depositAddress, cloneArgs, withdrawImpl, token, amount, proof)`. The manager invokes the clone's execute with the proof for the policy's withdraw leaf.
2. **Signed withdraw** (`signedWithdraw`) — Anyone with a valid EIP-712 signature from `signer` can trigger a withdrawal. The signed message is `SignedWithdraw(address depositAddress,address withdrawImpl,address token,uint256 amount,uint256 deadline)` — recipient is not part of the signature because it's fixed to `userAddress` inside the impl. The submitter supplies the merkle proof.

The `owner` can update `directWithdrawer` and `signer` addresses.

### Trust-Minimized User via TimelockController / Smart-Contract Wallet

Setting `cloneArgs.userAddress` to an OpenZeppelin `TimelockController` adds a time delay to all user-escape actions on the clone, giving the underlying beneficiary a window to react. No contract changes needed — the TimelockController address is set as `userAddress` at clone-deploy time. Smart-contract wallets (Safe, etc.) work the same way. Note: the withdraw destination is also that contract, so users who want a separate beneficiary can have the TimelockController / SCW forward funds onward.
