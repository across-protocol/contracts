# Counterfactual Deposit Addresses

Gas-optimized system for creating persistent, reusable deposit addresses via deterministic CREATE2 deployment. Deposits are executed via SponsoredCCTP.

## Architecture

**Two-contract system using OpenZeppelin EIP-1167 Clones with Immutable Args:**

- `CounterfactualDepositExecutor` — Implementation contract. Each deposit address is an EIP-1167 minimal proxy (clone) of this contract, with a keccak256 hash of the route parameters appended as the sole immutable arg (32 bytes). On execution, full params are passed by the caller, verified against the stored hash, and used to build a `SponsoredCCTPQuote` for `SponsoredCCTPSrcPeriphery.depositForBurn()`.
- `CounterfactualDepositFactory` — Deploys clones deterministically via `Clones.cloneDeterministicWithImmutableArgs`, predicts addresses, and routes execution calls.

```
                          ┌─────────────────────────────────────────┐
                          │       CounterfactualDepositFactory      │
                          │  - cloneDeterministicWithImmutableArgs  │
                          │  - predictDeterministicAddress          │
                          │  - admin management                     │
                          └──────────┬──────────────────────────────┘
                                     │ deploys
                    ┌────────────────┼────────────────┐
                    ▼                ▼                 ▼
            ┌──────────────┐ ┌──────────────┐  ┌──────────────┐
            │  Clone 0x1…  │ │  Clone 0x2…  │  │  Clone 0x3…  │
            │  (45 bytes   │ │  (45 bytes   │  │  (45 bytes   │
            │   + args)    │ │   + args)    │  │   + args)    │
            └──────┬───────┘ └──────┬───────┘  └──────┬───────┘
                   │ delegatecall   │                  │
                   └────────────────┼──────────────────┘
                                    ▼
                    ┌───────────────────────────────┐
                    │ CounterfactualDepositExecutor  │
                    │  - executeDeposit()            │
                    │  - adminWithdraw()             │
                    │  - userWithdraw()              │
                    │  - immutable: factory,         │
                    │    srcPeriphery, sourceDomain   │
                    └───────────────┬───────────────┘
                                    │ depositForBurn()
                                    ▼
                    ┌───────────────────────────────┐
                    │  SponsoredCCTPSrcPeriphery     │
                    │  - signature verification      │
                    │  - nonce tracking               │
                    │  - deadline enforcement          │
                    │  → CCTP depositForBurnWithHook  │
                    └───────────────────────────────┘
```

When a clone receives a call, the EIP-1167 bytecode `delegatecall`s to the executor. Inside that context:

- `address(this)` = the clone's address (holds token balances)
- Code executing = the executor's bytecode (has `factory`, `srcPeriphery`, `sourceDomain` immutables)
- Route params hash = read from the clone's bytecode via `Clones.fetchCloneArgs(address(this))`, verified against caller-supplied params

## SponsoredCCTPQuote Field Table

Each field in the `SponsoredCCTPQuote` is either a route param (committed via hash at address-generation time, passed at execution time), an executor immutable (same for all clones on a chain), computed at execution time, or passed by the caller at execution time:

| Field                  | Source                    | Explanation                                                                                   |
| ---------------------- | ------------------------- | --------------------------------------------------------------------------------------------- |
| `sourceDomain`         | **Executor immutable**    | Same for all deposits on this chain (e.g. 0 for Ethereum)                                     |
| `destinationDomain`    | **Route param**           | Route: which destination chain (e.g. 3 for Hyperliquid)                                       |
| `mintRecipient`        | **Route param**           | Route: DstPeriphery handler contract on destination chain                                     |
| `amount`               | **Passed on execution**   | Varies per deposit — clone may hold different balances each time                              |
| `burnToken`            | **Route param**           | Route: which token to burn (e.g. USDC address as bytes32)                                     |
| `destinationCaller`    | **Route param**           | Route: permissioned bot that calls `receiveMessage` on destination                            |
| `maxFee`               | **Computed on execution** | `amount * maxFeeBps / 10000` — computed from the route's `maxFeeBps` and the deposit `amount` |
| `minFinalityThreshold` | **Route param**           | Route: minimum finality before CCTP attestation is allowed                                    |
| `nonce`                | **Passed on execution**   | Unique per execution — SrcPeriphery enforces uniqueness                                       |
| `deadline`             | **Passed on execution**   | Expiration per execution attempt — SrcPeriphery enforces                                      |
| `maxBpsToSponsor`      | **Route param**           | Route: max basis points of amount the relayer can sponsor                                     |
| `maxUserSlippageBps`   | **Route param**           | Route: slippage tolerance for fees on destination                                             |
| `finalRecipient`       | **Route param**           | Route: ultimate receiver of tokens on destination chain                                       |
| `finalToken`           | **Route param**           | Route: token recipient gets on destination (may differ from burnToken if swapping)            |
| `destinationDex`       | **Route param**           | Route: which DEX on HyperCore for swaps                                                       |
| `accountCreationMode`  | **Route param**           | Route: Standard (0) or FromUserFunds (1)                                                      |
| `executionMode`        | **Route param**           | Route: DirectToCore (0), ArbitraryActionsToCore (1), or ArbitraryActionsToEVM (2)             |
| `actionData`           | **Route param**           | Route: encoded action data for arbitrary execution modes (empty for DirectToCore)             |

Additionally, `maxFeeBps` and `refundAddress` are route params that are not part of the SponsoredCCTPQuote:

| Field                  | Source          | Explanation                                                                   |
| ---------------------- | --------------- | ----------------------------------------------------------------------------- |
| `maxFeeBps`            | **Route param** | User's fee limit in basis points — used to compute `maxFee` at execution time |
| `userWithdrawAddress`  | **Route param** | Address authorized to call `userWithdraw()` — user's escape hatch             |
| `adminWithdrawAddress` | **Route param** | Address authorized to call `adminWithdraw()` — per-clone admin for recovery   |

## Key Design Decisions

### 1. Immutable Distribution (Gas Optimization)

**SrcPeriphery and sourceDomain are immutable in the Executor, not the clone.**

Why: These values are identical across all deposit addresses on a chain. Storing them in each clone wastes gas.

The clone only stores route-specific parameters (destinationDomain, burnToken, finalRecipient, admin, etc.) via a hash of the immutable args. Chain-wide constants live in the executor's bytecode and are accessible directly since EIP-1167 proxies use delegatecall.

### 2. Single Signature Model (No Second Signature Layer)

**The executor does NOT verify a separate quote signature — it relies entirely on SponsoredCCTPSrcPeriphery.**

Why: The SrcPeriphery already validates:

- **Signature** — quote must be signed by the authorized signer
- **Nonce** — prevents replay attacks
- **Deadline** — prevents stale quote execution
- **Source domain** — prevents cross-chain replay

Adding a second signature layer in the executor would be redundant and increase gas costs. The executor just builds the `SponsoredCCTPQuote` from its immutable args + execution params and forwards it.

### 3. maxFeeBps Instead of maxFee

**Users set `maxFeeBps` (basis points) as a clone immutable, not a raw `maxFee` amount.**

Why: At address-generation time, the deposit amount isn't known. The user commits to a fee percentage (e.g., 100 bps = 1%), and the executor computes `maxFee = amount * maxFeeBps / 10000` at execution time. This gives proportional fee protection regardless of deposit size.

### 4. OZ Clones with Hash-Only Immutable Args

**Each clone stores only a keccak256 hash (32 bytes) of the route parameters, not the full params (~595 bytes).**

[EIP-1167](https://eips.ethereum.org/EIPS/eip-1167) defines a minimal proxy contract — 45 bytes of bytecode that forwards every call to a fixed implementation via `delegatecall`. OpenZeppelin's `Clones.cloneDeterministicWithImmutableArgs` extends this by appending arbitrary bytes after the proxy bytecode.

**How it's used here:** The factory computes `keccak256(abi.encode(params))` and stores that 32-byte hash as the clone's sole immutable arg. At execution time, the caller passes the full `CounterfactualImmutables` struct; the executor hashes it and verifies against the stored hash before proceeding.

**Why a hash instead of the full params?**

Storing full params as immutable args costs ~595 bytes of deployed code. With a hash, the clone stores only 77 bytes total (45-byte EIP-1167 proxy + 32-byte hash). This saves ~103k gas on deployment (~200 gas per byte of `CODECOPY`). The tradeoff is ~6k gas more per execution (calldata for full params + one keccak256 hash), but since each deposit address is deployed once and potentially used many times, the net savings are significant — especially at scale with thousands of deposit addresses.

**Why not normal storage?** Storage-based alternatives are significantly more expensive:

- **SSTORE (cold)** costs 22,100 gas per slot on first write. Route params span many slots, so deploying a storage-based proxy would cost ~300k+ gas just for the writes — compared to the clone's total deployment cost of ~50k gas.
- **SLOAD (cold)** costs 2,100 gas per slot on first read within a transaction. Reading many slots is expensive. `EXTCODECOPY` reads the entire args blob in a single operation for ~2,600 gas (base) + minimal per-word cost.

### 5. Address Reusability

**The same clone proxy can receive and execute multiple deposits over time.**

Why: Enables persistent "deposit addresses" that users can save, share, and reuse — like a traditional address.

The factory's `deployAndExecute()` uses try/catch to handle already-deployed clones gracefully, while `executeOnExisting()` skips deployment entirely for subsequent deposits.

### 6. userWithdrawAddress and userWithdraw

**Each clone's route params include a `userWithdrawAddress`, and `userWithdraw()` lets only that address pull tokens out.**

Why: Provides an escape hatch for users who change their mind before execution. If a user sends tokens to their deposit address but doesn't want to proceed, they can call `userWithdraw()` with their route params to recover their funds without admin intervention. The route params are verified against the stored hash before checking the caller against `userWithdrawAddress`.

## Usage Pattern

**Initial setup:**

```solidity
address predictedAddress = factory.predictDepositAddress(executor, routeParams, salt);
// Share predictedAddress with user — tokens sent here before deployment are safe
```

**First deposit (deploys clone + executes):**

```solidity
factory.deployAndExecute(executor, routeParams, salt, amount, nonce, deadline, signature);
```

**Subsequent deposits (clone already deployed):**

```solidity
factory.executeOnExisting(depositAddress, routeParams, amount, nonce, deadline, signature);
```

## Security Model

- **SponsoredCCTP Signer**: Trusted address that signs CCTP quotes. Compromise allows bad quotes but fees are bounded by user-set `maxFeeBps`.
- **Admin**: Per-clone admin (set in route params at address-generation time). Can withdraw any tokens from its clone via `adminWithdraw` (for recovery of wrongly sent tokens). Can be a multisig or TimelockController for additional trust minimization.
- **userWithdrawAddress**: Can withdraw tokens from the clone via `userWithdraw` (escape hatch before execution).
- **Fee Protection**: `maxFeeBps` (clone immutable) bounds the `maxFee` passed to SponsoredCCTPSrcPeriphery proportionally.
- **Nonce Replay Protection**: Handled by SponsoredCCTPSrcPeriphery — each nonce can only be used once.
- **Deadline Enforcement**: Handled by SponsoredCCTPSrcPeriphery — expired quotes are rejected.

### Trust-Minimized Admin via TimelockController

The `admin` field can be set to any address — an EOA, a multisig, or an OpenZeppelin `TimelockController`. Using a `TimelockController` as the admin adds a time delay to all `adminWithdraw` calls, giving users a window to react:

1. A proposer schedules the `adminWithdraw` call on the TimelockController
2. The configured delay elapses (e.g., 24-48 hours)
3. During this window, the user can see the pending operation on-chain and call `userWithdraw` to pull their funds first
4. After the delay, an executor can execute the scheduled withdrawal

This requires no contract changes — the TimelockController address is simply set as the `admin` in the clone's `CounterfactualImmutables` at address-generation time. Since admin is committed in the params hash, users can verify the admin is a TimelockController with an adequate delay before depositing.
